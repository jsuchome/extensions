#!/bin/sh

set -e
set -u
set -o pipefail

# load org and project from repository if exists,
# if not, set them as a random string
if [ -e ".fuseml/_project" ]; then
    export ORG=$(cat .fuseml/_org)
    export PROJECT=$(cat .fuseml/_project)
else
    export ORG=$(tr -dc a-z0-9 </dev/urandom | head -c 6 ; echo '')
    export PROJECT=$(tr -dc a-z0-9 </dev/urandom | head -c 6 ; echo '')
fi

export S3_ENDPOINT=${MLFLOW_S3_ENDPOINT_URL/*:\/\//}

mc alias set minio ${MLFLOW_S3_ENDPOINT_URL} ${AWS_ACCESS_KEY_ID} ${AWS_SECRET_ACCESS_KEY}
model_bucket="minio${FUSEML_MODEL//s3:\//}"

export PREDICTOR=${FUSEML_PREDICTOR}
if [ "${PREDICTOR}" = "auto" ]; then
    if ! mc stat ${model_bucket}/MLmodel &> /dev/null ; then
        echo "No MLmodel found, cannot auto detect predictor"
        exit 1
    fi

    PREDICTOR=$(mc cat ${model_bucket}/MLmodel | awk -F '.' '/loader_module:/ {print $2}')
fi

sd="${ORG}-${PROJECT}"
case $PREDICTOR in
    sklearn)
        if ! mc ls ${model_bucket} | grep -q "model.joblib"; then
            mc cp ${model_bucket}/model.pkl ${model_bucket}/model.joblib
        fi
        export PREDICTOR_SERVER="SKLEARN_SERVER"
        prediction_url_path="${sd}/api/v1.0/predictions"
        ;;
esac

#TODO parametrize prediction method

# Gateway has host info in the form of '*.seldon.172.18.0.2.nip.io' so we need to add a prefix
domain=$(kubectl get Gateway seldon-gateway -n ${FUSEML_ENV_WORKFLOW_NAMESPACE} -o jsonpath='{.spec.servers[0].hosts[0]}')
export ISTIO_HOST="${ORG}.${PROJECT}${domain/\*/}"

envsubst < /root/template.sh | kubectl apply -f -

# rollout fails if the object does not exist yet, so we need to wait until it is created
count=0
until kubectl get SeldonDeployment ${sd} -n ${FUSEML_ENV_WORKFLOW_NAMESPACE}; do
  count=$((count + 1))
  if [[ ${count} -eq "30" ]]; then
    echo "Timed out waiting for SeldonDeployment to exist"
    exit 1
  fi
  sleep 2
done

kubectl rollout status deploy/$(kubectl get deploy -l seldon-deployment-id=${sd} -n ${FUSEML_ENV_WORKFLOW_NAMESPACE} -o jsonpath='{.items[0].metadata.name}') -n ${FUSEML_ENV_WORKFLOW_NAMESPACE}

prediction_url="http://${ISTIO_HOST}/seldon/${FUSEML_ENV_WORKFLOW_NAMESPACE}/${prediction_url_path}"

printf "${prediction_url}" > /tekton/results/${TASK_RESULT}

# Now, register the new application within fuseml

resources="{\"kind\": \"Secret\", \"name\": \"${ORG}-${PROJECT}-init-container-secret\"}, {\"kind\": \"ServiceAccount\", \"name\": \"${ORG}-${PROJECT}-seldon\"}, {\"kind\": \"SeldonDeployment\", \"name\": \"${ORG}-${PROJECT}\"}"

curl -X POST -H "Content-Type: application/json"  http://fuseml-core.fuseml-core.svc.cluster.local:80/applications -d "{\"name\":\"$sd\",\"description\":\"Application generated by $FUSEML_ENV_WORKFLOW_NAME workflow\", \"type\":\"predictor\",\"url\":\"$prediction_url\",\"workflow\":\"$FUSEML_ENV_WORKFLOW_NAME\", \"k8s_namespace\": \"$FUSEML_ENV_WORKFLOW_NAMESPACE\", \"k8s_resources\": [ $resources ]}"
