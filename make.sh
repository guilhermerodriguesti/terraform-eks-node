#!/bin/bash

# AWS variables
AWS_PROFILE="default"
AWS_REGION="us-east-1"
# root account id
ACCOUNT_ID=$(aws sts get-caller-identity \
        --query 'Account' \
        --profile $AWS_PROFILE \
        --output text)
# project variables
PROJECT_NAME="web-app"
WEBSITE_PORT="3000"

echo "Projeto:  $PROJECT_NAME"
# the directory containing the script file
#DIR="$(cd "$(dirname "$0")"; pwd)"
#DIR=$(cd "$(dirname "$0")"; pwd -P)
#DIR=$(dirname `readlink -f ${BASH_SOURCE[0]}`)
#DIR=$(dirname $(cd "$(dirname "$BASH_SOURCE")"; pwd))
#cd "$DIR"

# log()   { echo -e "\e[30;47m ${1^^} \e[0m ${@:2}"; }        # $1 uppercase background white
# info()  { echo -e "\e[48;5;28m\e[0m"; }      # $1 uppercase background green
# warn()  { echo -e "\e[48;5;202m ${1^^} \e[0m ${@:2}" >&2; } # $1 uppercase background orange
# error() { echo -e "\e[48;5;196m ${1^^} \e[0m ${@:2}" >&2; } # $1 uppercase background red

# log $1 in underline then $@ then a newline
# under() {
#     local arg=$1
#     shift
#     echo -e "\033[0;4m${arg}\033[0m ${@}"
#     echo
# }


id() {
ACCOUNT_ID=$(aws sts get-caller-identity \
        --query 'Account' \
        --profile $AWS_PROFILE \
        --output text)
 echo $ACCOUNT_ID
}

usage() {
    echo "usage call the Makefile directly: make dev
      or invoke this file directly: ./make.sh dev"
}

# install eksctl if missing (no update)
install-eksctl() {
    if [[ -z $(which eksctl) ]]
    then
        echo "install eksctl"
        echo "sudo is required"
        sudo wget -q -O - https://api.github.com/repos/weaveworks/eksctl/releases \
            | jq --raw-output 'map( select(.prerelease==false) | .assets[].browser_download_url ) | .[]' \
            | grep inux \
            | head -n 1 \
            | wget -q --show-progress -i - -O - \
            | sudo tar -xz -C /usr/local/bin

        # bash completion
        [[ -z $(grep eksctl_init_completion ~/.bash_completion 2>/dev/null) ]] \
            && eksctl completion bash >> ~/.bash_completion
    else
        echo "skip eksctl already installed"
    fi
}

# install yq if missing (no update)
install-yq() {
    if [[ -z $(which yq) ]]
    then
        echo "install yq"
        echo "sudo is required"
        cd /usr/local/bin
        local URL=$(wget -q -O - https://api.github.com/repos/mikefarah/yq/releases \
            | jq --raw-output 'map( select(.prerelease==false) | .assets[].browser_download_url ) | .[]' \
            | grep linux_amd64 \
            | head -n 1)
        sudo curl "$URL" \
            --progress-bar \
            --location \
            --output yq
        sudo chmod +x yq
    else
        echo "skip yq already installed"
    fi
}

# install kubectl if missing (no update)
install-kubectl() {
    if [[ -z $(which kubectl) ]]
    then
        echo "install eksctl"
        echo "sudo is required"
        local VERSION=$(curl --silent https://storage.googleapis.com/kubernetes-release/release/stable.txt)
        cd /usr/local/bin
        sudo curl https://storage.googleapis.com/kubernetes-release/release/$VERSION/bin/linux/amd64/kubectl \
            --progress-bar \
            --location \
            --remote-name
        sudo chmod +x kubectl
    else
        echo "skip kubectl already installed"
    fi
}

create-env() {
    # log install site npm modules
    #cd "$PWD/site"
    #npm install

    [[ -f "$PWD/.env" ]] && { echo "skip .env file already exists"; return; }
    echo "create .env file"

    # check if user already exists (return something if user exists, otherwise return nothing)
    local exists=$(aws iam list-user-policies \
        --user-name $PROJECT_NAME \
        --profile $AWS_PROFILE \
        2>/dev/null)
        
    [[ -n "$exists" ]] && { echo "abort user $PROJECT_NAME already exists"; return; }

    # create a user named $PROJECT_NAME
    echo "create iam user $PROJECT_NAME"
    aws iam create-user \
        --user-name $PROJECT_NAME \
        --profile $AWS_PROFILE \
        1>/dev/null

    aws iam attach-user-policy \
        --user-name $PROJECT_NAME \
        --policy-arn arn:aws:iam::aws:policy/PowerUserAccess \
        --profile $AWS_PROFILE

    local key=$(aws iam create-access-key \
        --user-name $PROJECT_NAME \
        --query 'AccessKey.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey}' \
        --profile $AWS_PROFILE \
        2>/dev/null)

    local AWS_ACCESS_KEY_ID=$(echo "$key" | jq '.AccessKeyId' --raw-output)
    echo "AWS_ACCESS_KEY_ID $AWS_ACCESS_KEY_ID"
    
    local AWS_SECRET_ACCESS_KEY=$(echo "$key" | jq '.SecretAccessKey' --raw-output)
    echo "AWS_SECRET_ACCESS_KEY $AWS_SECRET_ACCESS_KEY"

    # create ECR repository
    local repo=$(aws ecr describe-repositories \
        --repository-names $PROJECT_NAME \
        --region $AWS_REGION \
        --profile $AWS_PROFILE \
        2>/dev/null)
    if [[ -z "$repo" ]]
    then
        echo "ecr create-repository $PROJECT_NAME"
        local AWS_ECR_REPOSITORY=$(aws ecr create-repository \
            --repository-name $PROJECT_NAME \
            --region $AWS_REGION \
            --profile $AWS_PROFILE \
            --query 'repository.repositoryUri' \
            --output text)
        echo "AWS_ECR_REPOSITORY $AWS_ECR_REPOSITORY"
    fi

    # envsubst tips : https://unix.stackexchange.com/a/294400
    # create .env file
    cd "$PWD"
    # export variables for envsubst
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_ECR_REPOSITORY
    envsubst < .env.tmpl > .env

    echo "created file .env"
}

# install eksctl + kubectl + yq, create aws user + ecr repository
setup() {
    install-eksctl
    install-kubectl
    install-yq
    tf-init
    create-env
}

# local development (by calling npm script directly)
dev() {
    cd "$PWD/site"
    npm run-script dev
}

# run tests (by calling npm script directly)
test() { 
    cd "$PWD/site"
    npm test
}

# build the production image locally
build() {
    cd "$PWD/site"
    local VERSION=$(jq --raw-output '.version' package.json)
    echo "build $PROJECT_NAME:$VERSION"
    docker image build \
        --tag $PROJECT_NAME:latest \
        --tag $PROJECT_NAME:$VERSION \
        .
}

# run the latest built production image on localhost
run() {
    [[ -n $(docker ps --format '{{.Names}}' | grep $PROJECT_NAME) ]] \
        && { echo "container already exists"; return; }
    echo "run $PROJECT_NAME on http://localhost:80"
    docker run \
        --detach \
        --name $PROJECT_NAME \
        --publish 80:$WEBSITE_PORT \
        $PROJECT_NAME
}

# remove the running container
rm() {
    [[ -z $(docker ps --format '{{.Names}}' | grep $PROJECT_NAME) ]]  \
        && { echo "no running container found"; return; }
    docker container rm \
        --force $PROJECT_NAME
}

tf-init() {
    echo "terraform init"
    cd "$PWD/infra"
    terraform init
}

plan() {
    cd "$PWD/infra"
    terraform fmt -recursive
    terraform plan
}
# terraform vallidate
validate() {
    cd "$PWD/infra"
    terraform fmt -recursive
    terraform validate
}

destroy() {
    echo "terraform destroy"
    cd "$PWD/infra"
    terraform destroy -auto-approve

}
# create the EKS cluster
cluster-create() {
    # check if cluster already exists (return something if the cluster exists, otherwise return nothing)
    local exists=$(aws eks describe-cluster \
        --name $PROJECT_NAME \
        --profile $AWS_PROFILE \
        --region $AWS_REGION \
        2>/dev/null)
        
    [[ -n "$exists" ]] && { echo "abort cluster $PROJECT_NAME already exists"; return; }

    # create a cluster named $PROJECT_NAME
    echo "create eks cluster $PROJECT_NAME"

    # terraform plan + terraform apply
    cd "$PWD/infra"
    terraform plan
    terraform apply -auto-approve

    echo "setup kubectl config"
    # setup kubectl config
    aws eks update-kubeconfig \
        --name $(terraform output -raw cluster_name) \
        --region $(terraform output -raw region)

    echo "kubectl config current-context"
    # must be like : arn:aws:eks:us-east-1:xxxx:cluster/project_name
    kubectl config current-context
}

# create kubectl EKS configuration
cluster-create-config() {
    echo "create kubeconfig.yaml"
    CONTEXT=$(kubectl config current-context)
    echo "context $CONTEXT"
    kubectl config view --context=$CONTEXT --minify > kubeconfig.yaml

    echo "inject certificate"
    # yq tips: https://mikefarah.gitbook.io/yq/usage/path-expressions#with-prefixes
    CERTIFICATE=$(yq read $HOME/.kube/config "clusters.(name==$CONTEXT).cluster.certificate-authority-data")
    echo "certificate $CERTIFICATE"
    yq write --inplace kubeconfig.yaml 'clusters[0].cluster.certificate-authority-data' $CERTIFICATE

    echo "delete env values"
    yq delete --inplace kubeconfig.yaml 'users[0].user.exec.env'

    echo "create KUBECONFIG file"
    cat kubeconfig.yaml | base64 --wrap 0 > KUBECONFIG

    echo "configmap get configmap aws-auth file"
    kubectl -n kube-system get configmap aws-auth -o yaml > aws-auth-configmap.yaml

    echo "inject the lines below in aws-auth-configmap.yaml"
    echo "mapUsers: |
    - userarn: arn:aws:iam::$ACCOUNT_ID:user/$PROJECT_NAME
      username: $PROJECT_NAME
      groups:
        - system:masters"
}

# apply kubectl EKS configuration
cluster-apply-config() {
    # check if data.mapUsers is configured (return something if data.mapUsers is configured, otherwise return nothing)
    local exists=$(yq read aws-auth-configmap.yaml data.mapUsers)
    [[ -z "$exists" ]] && { echo "abort data.mapUsers not configured in aws-auth-configmap.yaml"; return; }

    echo "apply aws-auth-configmap.yaml"
    kubectl -n kube-system apply -f aws-auth-configmap.yaml

    echo "test kubectl get ns"
    source "$PWD/.env"
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    kubectl --kubeconfig kubeconfig.yaml get ns
}

# get the cluster ELB URL
cluster-elb() {
    kubectl get svc \
        --namespace $PROJECT_NAME \
        --output jsonpath="{.items[?(@.metadata.name=='website')].status.loadBalancer.ingress[].hostname}"
}

# delete the EKS cluster
cluster-delete() {
    # delete eks content
    echo "delete namespace $PROJECT_NAME"
    kubectl delete ns $PROJECT_NAME --ignore-not-found --wait

    # terraform destroy
    cd "$PWD/infra"
    terraform destroy -auto-approve
}



# if `$1` is a function, execute it. Otherwise, print usage
# compgen -A 'function' list all declared functions
# https://stackoverflow.com/a/2627461
FUNC=$(compgen -A 'function' | grep $1)
[[ -n $FUNC ]] && { echo "Applying" $1; eval $1; } || usage;
exit 0