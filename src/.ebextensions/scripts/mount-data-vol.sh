#!/bin/bash
# this script require the instance has the IAM right of handling volumes like below
# it also depens on the Tag Name 'Name'(instance name, and volume name) that is on both the volume and instance for matching
# this instance can only be within single availability zone(volume is local) and single instance in elasticbeanstalk
# {
#     "Version": "2012-10-17",
#     "Statement": [
#         {
#             "Effect": "Allow",
#             "Action": [
#                 "ec2:AttachVolume",
#                 "ec2:DetachVolume",
#                 "ec2:DescribeVolumes"
#             ],
#             "Resource": [
#                 "arn:aws:ec2:*:*:volume/*",
#                 "arn:aws:ec2:*:*:instance/*"
#             ]
#         }
#     ]
# }
# below may not be the case !!!
export ROOT_VOLUME_NAME=$(lsblk -d -P | head -n 1 | grep -o 'NAME="[a-z0-9]*"' | grep -o '[a-z0-9]*')
export REGION=$(/opt/aws/bin/ec2-metadata -z | awk '{print substr($2, 0, length($2)-1)}')
export INSTANCE_ID=$(/opt/aws/bin/ec2-metadata -i | awk '{print $2}')
export MACHINE_NAME=$(aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value]' | jq -r '.[0][0][0][0]')
echo $MACHINE_NAME
if [ "${MACHINE_NAME}" == "" ] || [ ${MACHINE_NAME} == "null" ]; then
        echo "no machine name defined, won't mount data volume"
        exit 0
fi
export VOLUME_ID=$(aws ec2 describe-volumes --region ${REGION} --output text --filters Name=tag:Name,Values=${MACHINE_NAME} --query 'Volumes[*].VolumeId')
echo $VOLUME_ID
if [ "${VOLUME_ID}" == "" ] || [ ${VOLUME_ID} == "null" ]; then
        echo "no volume for machine ${MACHINE_NAME}, won't mount data volume"
        exit 0
fi
export MOUNT_POINT=/mnt/data
export DEVICE=/dev/nvme1n1
if [ ! -b "${DEVICE}" ]; then
        echo "attaching volume ${VOLUME_ID}"
        aws ec2 attach-volume --region ${REGION} --device /dev/sdh --instance-id ${INSTANCE_ID} --volume-id ${VOLUME_ID}
        aws ec2 wait volume-in-use --region ${REGION} --volume-ids ${VOLUME_ID}
        sleep 10
else
        echo "volume already attached"
        aws ec2 wait volume-in-use --region ${REGION} --volume-ids ${VOLUME_ID}
fi

# Now lsblk should show two devices. We figure out which one is non-root by filtering out the stored root volume name.
NON_ROOT_VOLUME=$(lsblk -d -P | grep -o 'NAME="[a-z0-9]*"' | grep -o '[a-z0-9]*' | awk -v name="$ROOT_VOLUME_NAME" '$0 !~ name')
#NON_ROOT_VOLUME_UUID=$(lsblk -d -P -o +UUID | awk -v name="$NON_ROOT_VOLUME" '$0 ~ name' | grep -o 'UUID="[-0-9a-z]*"' | grep -o '[-0-9a-z]*')
NON_ROOT_DEVICE=${DEVICE}
echo "data volume device ${NON_ROOT_DEVICE}"
export RAW_VOLUME=$(file -s ${NON_ROOT_DEVICE} | awk '{print $2}' | grep -q data)
if [ "$RAW_VOLUME" != "" ]; then
        echo "creating new file system type ext4"
        mkfs -t ext4 ${NON_ROOT_DEVICE}
else
        echo "existing file system"
        file -s ${NON_ROOT_DEVICE}
fi
if [ ! -d "${MOUNT_POINT}" ]; then
        mkdir -p ${MOUNT_POINT}
fi
if mountpoint ${MOUNT_POINT}; then
        echo "volume aleady mounted to ${MOUNT_POINT}"
else
        echo "mount data volume to ${MOUNT_POINT}"
        mount ${NON_ROOT_DEVICE} ${MOUNT_POINT}
        grep -E "$MOUNT_POINT" /etc/fstab || echo "${NON_ROOT_DEVICE} ${MOUNT_POINT} ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
fi
