#!/bin/bash
sflag=false
pflag=false

DIRNAME=$(dirname "$0")
STACK_NAME=sdlf-engineering-weather-glue-job

usage () { echo "
    -h -- Opens up this help message
    -p -- Name of the AWS profile to use
    -s -- Name of S3 bucket to upload artifacts to
"; }
options=':p:s:h'
while getopts $options option
do
    case "$option" in
        p  ) pflag=true; PROFILE=$OPTARG;;
        s  ) sflag=true; S3_BUCKET=$OPTARG;;
        h  ) usage; exit;;
        \? ) echo "Unknown option: -$OPTARG" >&2; exit 1;;
        :  ) echo "Missing option argument for -$OPTARG" >&2; exit 1;;
        *  ) echo "Unimplemented option: -$OPTARG" >&2; exit 1;;
    esac
done

if ! $pflag
then
    echo "-p not specified, using default..." >&2
    PROFILE="default"
fi
if ! $sflag
then
    S3_BUCKET=$(sed -e 's/^"//' -e 's/"$//' <<<"$(aws ssm get-parameter --name /SDLF/S3/CFNBucket --profile $PROFILE --query "Parameter.Value")")
fi

echo "Checking if bucket exists ..."
if ! aws s3 ls $S3_BUCKET --profile $PROFILE; then
  echo "S3 bucket named $S3_BUCKET does not exist. Create? [Y/N]"
  read choice
  if [ $choice == "Y" ] || [ $choice == "y" ]; then
    aws s3 mb s3://$S3_BUCKET --profile $PROFILE
  else
    echo "Bucket does not exist. Deploy aborted."
    exit 1
  fi
fi

ARTIFACTS_BUCKET=$(sed -e 's/^"//' -e 's/"$//' <<<"$(aws ssm get-parameter --name /SDLF/S3/ArtifactsBucket --profile $PROFILE --query "Parameter.Value")")
aws s3 cp "$DIRNAME/scripts/weather-glue-job.py" "s3://$ARTIFACTS_BUCKET/artifacts/" --profile $PROFILE

mkdir $DIRNAME/output

aws cloudformation package --template-file $DIRNAME/scripts/weather-glue-job.yaml \
  --s3-bucket $S3_BUCKET \
  --profile $PROFILE \
  --output-template-file $DIRNAME/output/packaged-template.yaml

if ! aws cloudformation describe-stacks --profile $PROFILE --stack-name $STACK_NAME; then
  echo -e "Stack does not exist, creating ..."
  aws cloudformation create-stack \
  --profile $PROFILE \
  --stack-name $STACK_NAME \
  --template-body file://$DIRNAME/output/packaged-template.yaml \
  --capabilities "CAPABILITY_NAMED_IAM" "CAPABILITY_AUTO_EXPAND"

  echo "Waiting for stack to be created ..."
  aws cloudformation wait stack-create-complete --profile $PROFILE \
    --stack-name $STACK_NAME

else
  echo -e "Stack exists, attempting update ..."

  set +e
  update_output=$(aws cloudformation update-stack \
    --profile $PROFILE \
    --stack-name $STACK_NAME \
    --template-body file://$DIRNAME/output/packaged-template.yaml \
    --capabilities "CAPABILITY_NAMED_IAM" "CAPABILITY_AUTO_EXPAND" 2>&1)
  status=$?
  set -e

  echo "$update_output"

  if [ $status -ne 0 ] ; then
    # Don't fail for no-op update
    if [[ $update_output == *"ValidationError"* && $update_output == *"No updates"* ]] ; then
      echo -e "\nFinished create/update - no updates to be performed";
      exit 0;
    else
      exit $status
    fi
  fi

  echo "Waiting for stack update to complete ..."
  aws cloudformation wait stack-update-complete --profile $PROFILE \
    --stack-name $STACK_NAME
  echo "Finished create/update successfully!"
fi