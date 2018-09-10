# AWS tooling bash scripts.

Summary - place this file and the ami_creation folder inside of the roof of your puppet directory. 
Use this script to create a new AMI for an instance given only a node name. 
Everything in the puppet manifest should be able to run without needing anything other than the instance's target FQDN (Fully Qualified Domain Name).

##SAMPLE Puppet layout:##

**Directories**
./puppet/
./puppet/environments
./puppet/environments/production/manifests/
./hieradata
./hieradata/node


Main entrypoint for puppet manifests (place node definitions here)
./puppet/environments/production/manifests/main.pp

## Puppetfile ##
```Ruby
#!/usr/bin/env ruby
#^syntax detection
forge "https://forgeapi.puppetlabs.com"

# A module from a git branch/tag
# mod 'puppetlabs-apt',
#   :git => 'https://github.com/puppetlabs/puppetlabs-apt.git',
#   :ref => '1.4.x'

mod 'puppetlabs-apache'
mod 'puppetlabs-apt'
mod 'puppetlabs-mysql'
mod 'puppetlabs-ntp', '7.2.0'
mod 'walkamongus-codedeploy', '1.0.1'
mod 'saz-ssh', '4.0.0'
mod 'saz-timezone', '5.0.2'
mod 'thias-sysctl', '1.0.6'
## A local module that you want copied from ./puppet/local_modules/{MODULE_NAME} into ./puppet/modules/{MODULE_NAME}
mod 'example-java8',
  :path => "local_modules/java8"
```


## create_ami_from_puppet.sh help menu:
Special notes: The IAM Profile performing this must be able to create and terminate instances, access security groups, and create AMIs

-h Display this menu
* -a - Base AMI to start with (See: https://cloud-images.ubuntu.com/locator/ec2/  Suggested: ami-059e7901352ebaef8)
  -e EC2 instance type. E.g., t2.micro (default)
* -f {Desired node name. This is what we want to use as the left-half for name organization}
* -g AWS Security Group
* -i PATH on the system executing this command to the SSH Key to authenticate against the instance with. Must correspond to the -g argument's key name on AWS.
* -k AWS Root SSH Key name (e.g., root_key_pair -- This MUST correspond to the -i SSH-key being used)
* -p AWS Profile name
* -r AWS Region (e.g., us-west-1)
* -s AWS Subnet to put the instance under (Must be internet routable)
* -o AWS IAM prOfile ;-) -- this is needed if the puppet manifest needs to install AWS CodeDeploy  because that requires S3 permissions.
* -t Keep the instance alive even if there's a failure along the way -- e.g., you want to spin up an instance and keep on fiddling with puppet after it breaks.

* Indicated a required option.



The output of this script is an AMI if things worked out. 
Add -t to the end of the script if you are working with experimental puppet manifests (you aren't sure if they are just right) to NOT terminate the instance if it's successful or if it fails. 
This is useful so you can just rsync any changes and re-run the puppet apply command directly on the instance until you're satisfied that it operates as expected.


