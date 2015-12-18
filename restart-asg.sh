#!/bin/bash -ex
export http_proxy=${PROXY)
export https_proxy=${PROXY}
export no_proxy=${NO_PROXY}
# Temporarily escalate our privileges
STS_CREDS=$(aws sts assume-role \
	--role-arn arn:aws:iam::${ACCOUNT_NUMBER}:role/${ROLE} \
    --role-session-name aws-ha-release \
    --duration-seconds 900 \
    --output text)
export AWS_ACCESS_KEY_ID=$(echo ${STS_CREDS} | cut -d' ' -f5)
export AWS_SECRET_ACCESS_KEY=$(echo ${STS_CREDS} | cut -d' ' -f7)
export AWS_SESSION_TOKEN=$(echo ${STS_CREDS} | cut -d' ' -f8)
echo "Assumed role: $(echo ${STS_CREDS} | cut -d' ' -f2)"

#Key file must be at root of private repository.
chmod 700 ${SSH_KEY_FILE}

# First, figure out whether our CFN stack exists
if [ -z "$(aws cloudformation describe-stacks --stack-name ${STACK_NAME} --output text 2>/dev/null)" ]; then
	echo "Could not find CFN stack $STACK_NAME. Aborting!"
    exit 79
fi
# Get the name of the autoscaling group for that stack
ASG=$(aws cloudformation list-stack-resources --stack-name ${STACK_NAME} \
	--query 'StackResourceSummaries[?ResourceType==`AWS::AutoScaling::AutoScalingGroup`].PhysicalResourceId[]' \
    --output text --region ${REGION})

#creates variable containing Auto Scaling Group
asg_result=`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${ASG}" --region ${REGION}`
asg_instance_list=`echo "$asg_result" | grep InstanceId | sed 's/.*i-/i-/' | sed 's/",//'`

#validate - the pipeline of echo -e "$asg_result" | grep -c "AutoScalingGroupARN"  must only return one group found - in the case below - more than one group has been found
if [[ `echo -e "$asg_result" | grep -c "AutoScalingGroupARN"` > 1  ]]
	then echo "More than one Auto Scaling Group found. As more than one Auto Scaling Group has been found, reboot does not know which Auto Scaling Group should have Instances terminated." 1>&2 ; exit 64
fi
#validate - the pipeline of echo -e "$asg_result" | grep -c "AutoScalingGroupARN"  must only return one group found
if [[ `echo -e "$asg_result" | grep -c "AutoScalingGroupARN"` < 1 ]]
	then echo "No Auto Scaling Group was found. Because no Auto Scaling Group has been found, reboot does not know which Auto Scaling Group should have Instances terminated." 1>&2 ; exit 64
fi

echo -e "The list of Instances in Auto Scaling Group ${ASG} that will be rebooted is below:\n$asg_instance_list"

as_processes_to_suspend="ReplaceUnhealthy AlarmNotification ScheduledActions AZRebalance"
aws autoscaling suspend-processes --auto-scaling-group-name "${ASG}" --scaling-processes $as_processes_to_suspend --region ${REGION}

#and begin recycling instances
for instance_selected in $asg_instance_list
do
    echo "Instance $instance_selected will now be restarted." 
    instance_info=`aws ec2 describe-instances --filters "Name=instance-id,Values=${instance_selected}" --region ${REGION}`
    private_ip=`echo "$instance_info" | grep -m 1 PrivateIpAddress | sed 's/.*10\./10\./' | sed 's/",//'` 
    ssh-keygen -R $private_ip
    ssh -o StrictHostKeyChecking=no -v -i ${SSH_KEY_FILE} ec2-user@$private_ip sudo ${RESTART_SCRIPT}
    sleep 20

done

aws autoscaling resume-processes --auto-scaling-group-name "${ASG}" --region ${REGION}

