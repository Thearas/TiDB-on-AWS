local tidbClusterVersion = std.extVar('TiDBClusterVersion');
local SUPPORTED_TIUP_COMPONENTS = ['PD', 'TiDB', 'TiKV'];
local SUPPORTED_INSTANCE_TYPES = ['a1.medium', 'a1.large', 'a1.xlarge', 'a1.2xlarge', 'a1.4xlarge', 'a1.metal'];

local newEC2Instance(instanceType) = {
  Type: 'AWS::EC2::Instance',
  CreationPolicy: { ResourceSignal: { Timeout: 'PT15M' } },
  Metadata: {
    'AWS::CloudFormation::Init': {
      configSets: {
        Setup: ['add_user', 'config_ssh'],
      },
      add_user: {
        commands: {
          adduser: { command: "sudo su - root -c 'useradd -m tidb'" },
          sudoer: { command: "sudo su - root -c 'echo \"tidb ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/tidb'" },
          chmod: { command: "sudo su - tidb -c 'mkdir -p /home/tidb/.ssh/ && chmod 0700 /home/tidb/.ssh/'" },
        },
      },
      config_ssh: {
        files: {
          '/home/tidb/.ssh/authorized_keys': {
            content: { Ref: 'TiDBClusterPublicKey' },
            mode: '000400',
            owner: 'root',
            group: 'root',
          },
        },
      },
    },
  },
  Properties: {
    ImageId: { Ref: 'LatestAmiId' },
    InstanceType: instanceType,
    KeyName: { Ref: 'KeyName' },
    SecurityGroups: [{ Ref: 'TiDBSecurityGroup' }],
    UserData: {
      'Fn::Base64': {
        'Fn::Sub': |||
          #!/bin/bash -xe
          yum update -y aws-cfn-bootstrap
          /opt/aws/bin/cfn-init -v --stack ${AWS::StackId} --resource TiDBInstance --configsets Setup --region ${AWS::Region}
          /opt/aws/bin/cfn-signal -e $? --stack ${AWS::StackId} --resource TiDBInstance --region ${AWS::Region}
        |||,
      },
    },
  },
};

{
  tidb:: {
    new():: {
      AWSTemplateFormatVersion: '2010-09-09',
      Description: 'Deploy TiDB Cluster on AWS EC2',
      Parameters: {
        TiDBClusterPrivateKey: {
          ConstraintDescription: 'must be a private key',
          Description: 'SSH private key used by tiup',
          Type: 'String',
          NoEcho: true,
        },
        TiDBClusterPublicKey: {
          ConstraintDescription: 'must be a public key',
          Description: 'SSH public key used by tiup',
          Type: 'String',
        },
        KeyName: {
          ConstraintDescription: 'must be the name of an existing EC2 KeyPair',
          Description: 'Name of an existing EC2 KeyPair to enable SSH access to the instances',
          Type: 'AWS::EC2::KeyPair::KeyName',
        },
        SSHLocation: {
          AllowedPattern: '(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})/(\\d{1,2})',
          ConstraintDescription: 'must be a valid IP CIDR range of the form x.x.x.x/x',
          Default: '0.0.0.0/0',
          Description: 'The IP address range that can be used to SSH to the EC2 instances',
          MaxLength: '18',
          MinLength: '9',
          Type: 'String',
        },
        LatestAmiId: {
          Type: 'AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>',
          Default: '/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2',
        },
      },
      Resources: {
        TiDBSecurityGroup: {
          Type: 'AWS::EC2::SecurityGroup',
          Properties: {
            GroupDescription: 'Enable TiDB and SSH port',
            SecurityGroupIngress:
              [
                // ssh port
                {
                  IpProtocol: 'tcp',
                  FromPort: 22,
                  ToPort: 22,
                  CidrIp: { Ref: 'SSHLocation' },
                },
              ] + [
                // tidb component ports
                {
                  IpProtocol: 'tcp',
                  FromPort: port,
                  ToPort: port,
                  CidrIp: '0.0.0.0/0',
                }
                for port in [4000, 2379, 2380, 10080, 20160, 20180]
              ],
          },
        },
      },
      Outputs: {},
    } + self,

    component:: {
      new(name)::
        assert std.find(name, SUPPORTED_TIUP_COMPONENTS) != [] : 'unsupported component, expect on of %s' % std.toString(SUPPORTED_TIUP_COMPONENTS);
        {
          name: name,
          replicas: 1,
          instanceType: 'a1.medium',
        } + self,
      replicas(n):: self + { replicas: n },
      instantType(t)::
        assert std.find(t, SUPPORTED_INSTANCE_TYPES) != [] : 'no such instance type, expect on of %s' % std.toString(SUPPORTED_INSTANCE_TYPES);
        self + { instanceType: t },
    },

    getInstanceOf(component):: std.filter(function(ins) self.Resources[ins].Type == 'AWS::EC2::Instance' && std.startsWith(ins, component), std.objectFields(self.Resources)),

    withComponents(components=[]):: self + {
      Resources+: {
        [c.name + i]: newEC2Instance(c.instanceType)
        for c in components
        for i in std.range(0, c.replicas)
      },

      Outputs+: {
        [ins + 'PublicIp']: {
          Description: 'Public Ip of %s server' % ins,
          Value: { 'Fn::GetAtt': [ins, 'PublicIp'] },
        }
        for ins in self.getInstanceOf('TiDB')
      },
    },

    buildWithTestServer(testServerInstanceType)::
      local hostsOf(component) = std.lines(['- host: ${%s.PublicIp}' % ins for ins in self.getInstanceOf(component)]);
      local tiupComponentsConfig = std.lines([
        'pd_servers:',
        hostsOf('PD'),
        'tidb_servers:',
        hostsOf('TiDB'),
        'tikv_servers:',
        hostsOf('TiKV'),
      ]);

      self + {
        Resources+: {
          // TestServer will run `tiup cluster deploy` and the test command
          TestServer: newEC2Instance(testServerInstanceType) + { Metadata+: { 'AWS::CloudFormation::Init'+: {
            configSets+: { Setup+: ['deps', 'setup_tidb_cluster'] },
            deps: {
              packages: { yum: { mysql: [] } },
              commands: {
                install_tiup: { command: "curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh" },
              },
              files: {
                '/root/tidb.pem': {
                  content: { Ref: 'TiDBClusterPrivateKey' },
                  mode: '000400',
                  owner: 'root',
                  group: 'root',
                },
                '/root/deploy.yaml': {
                  content: {
                    'Fn::Sub': |||
                                 global:
                                   user: "tidb"
                                   ssh_port: 22
                                   deploy_dir: "/home/tidb/tidb-cluster-deploy"
                                   data_dir: "/home/tidb/tidb-cluster-data"
                               |||
                               + tiupComponentsConfig,
                  },
                  mode: '000600',
                  owner: 'root',
                  group: 'root',
                },
              },
            },
            setup_tidb_cluster: {
              commands: {
                tiup_cluster_install: { command: '/root/.tiup/bin/tiup install cluster' },
                deploy: { command: '/root/.tiup/bin/tiup cluster deploy test-cluster %s /root/deploy.yaml -u tidb -y --ignore-config-check -i /root/tidb.pem &> /root/tidb_deploy.log' % tidbClusterVersion },
                start: { command: '/root/.tiup/bin/tiup cluster start test-cluster' },
              },
            },
          } } },
        },
      },
  },
}
