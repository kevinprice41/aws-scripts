#!/bin/bash -ex

export http_proxy=${PROXY}
export https_proxy=${PROXY}
export no_proxy=${NO_PROXY}
# Temporarily escalate our privileges
STS_CREDS=$(aws sts assume-role \
	--role-arn ${ROLE_ARN} \
    --role-session-name reboot_session \
    --duration-seconds 900 \
    --output text)
export AWS_ACCESS_KEY_ID=$(echo ${STS_CREDS} | cut -d' ' -f5)
export AWS_SECRET_ACCESS_KEY=$(echo ${STS_CREDS} | cut -d' ' -f7)
export AWS_SESSION_TOKEN=$(echo ${STS_CREDS} | cut -d' ' -f8)
echo "Assumed role: $(echo ${STS_CREDS} | cut -d' ' -f2)"

# First, figure out whether our CFN stack exists
if [ -z "$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --output text 2>/dev/null)" ]; then
	echo "Could not find CFN stack $STACK_NAME. Aborting!"
    exit 79
fi
# Get the name of the autoscaling group for that stack
asg_id=$(aws cloudformation list-stack-resources --stack-name ${STACK_NAME} \
	--query 'StackResourceSummaries[?ResourceType==`AWS::AutoScaling::AutoScalingGroup`].PhysicalResourceId[]' \
    --output text)

#creates variable containing Auto Scaling Group
asg_result=`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${asg_id}" --region ${REGION}`
#get instance ids associated with asg
asg_instance_list=`echo "$asg_result" | grep InstanceId | sed 's/.*i-/i-/' | sed 's/",//'`

#validate - the pipeline of echo -e "$asg_result" | grep -c "AutoScalingGroupARN"  must only return one group found - in the case below - more than one group has been found
if [[ `echo -e "$asg_result" | grep -c "AutoScalingGroupARN"` > 1  ]]
	then echo "More than one Auto Scaling Group found. As more than one Auto Scaling Group has been found, reboot does not know which Auto Scaling Group should have Instances terminated." 1>&2 ; exit 64
fi
#validate - the pipeline of echo -e "$asg_result" | grep -c "AutoScalingGroupARN"  must only return one group found
if [[ `echo -e "$asg_result" | grep -c "AutoScalingGroupARN"` < 1 ]]
	then echo "No Auto Scaling Group was found. Because no Auto Scaling Group has been found, reboot does not know which Auto Scaling Group should have Instances terminated." 1>&2 ; exit 64
fi

echo -e "The list of Instances in Auto Scaling Group ${asg_id} that will be rebooted is below:\n$asg_instance_list"

as_processes_to_suspend="ReplaceUnhealthy AlarmNotification ScheduledActions AZRebalance"
aws autoscaling suspend-processes --auto-scaling-group-name "${ASG}" --scaling-processes $as_processes_to_suspend --region ${REGION}

#and begin recycling instances
for instance_selected in $asg_instance_list
do
  echo "Instance $instance_selected will now be rebooted."
  aws ec2 reboot-instances --instance-ids $instance_selected  > /dev/null
  sleep 60  
  STATUS=$(aws ec2 describe-instance-status --instance-id $instance_selected \
    --query 'InstanceStatuses[0].InstanceStatus.Status' --region ${REGION} --output text)

  while [ "$STATUS" != "ok" ]; do
   echo "Status Equal To ${STATUS}"
   sleep 30
   STATUS=$(aws ec2 describe-instance-status --instance-id $instance_selected \
       --query 'InstanceStatuses[0].InstanceStatus.Status' --region ${REGION} --output text)
  done

done

#resume the scaling processes that was suspended 
aws autoscaling resume-processes --auto-scaling-group-name "${ASG}" --region ${REGION}
