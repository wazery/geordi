require 'aws-sdk-ec2'
require 'aws-sdk-autoscaling'

module Geordi
  class CapistranoConfig
    attr_accessor :root

    def initialize(stage)
      self.stage = stage
      self.root = find_project_root!
      load_deploy_info
    end

    def user(server)
      @cap2user ||= deploy_info[ /^\s*set\s*:aws_deploy_user,\s*['"](.*?)['"]/, 1 ]
      @cap2user || deploy_info[ /^\s*server\s*['"]#{ server }['"],.*user.{1,4}['"](.*?)['"]/m, 1 ]
    end
    
    def asg_group_name
      @asg_group_name ||= deploy_info[ /^\s*set\s*:aws_autoscaling_group_name,\s*['"](.*?)['"]/, 1 ]
    end

    def servers
      autoscaling_client   = ::Aws::AutoScaling::Client.new(region: region, credentials: credentials)
      autoscaling_resource = ::Aws::AutoScaling::Resource.new(client: autoscaling_client)
      ec2_client           = ::Aws::EC2::Client.new(region: region, credentials: credentials)
      ec2_resource         = ::Aws::EC2::Resource.new(client: ec2_client)
      autoscaling_group    = autoscaling_resource.group(asg_group_name)
      asg_instances        = autoscaling_group.instances

      asg_instances.map do |asg_instance|
        next if asg_instance.health_status != 'Healthy'

        ec2_instance = ec2_resource.instance(asg_instance.id)
        { ip: ec2_instance.public_ip_address, type: "AutoScaling" }
      end + deploy_info.scan(/(\d+\.\d+\.\d+\.\d+).*sidekiq/).flatten.map { |ip| { ip: ip, type: "Sidekiq"} }
    end

    def primary_server
      # Actually, servers may have a :primary property. From Capistrano 3, the
      # first listed server is the primary one by default, which is a good-
      # enough default for us.
      servers.first
    end

    def remote_root
      File.join deploy_info[ /^\s*set\s*:deploy_to,\s*['"](.*?)['"]/, 1 ], 'current'
    end

    def env
      deploy_info[ /^\s*set\s*:rails_env,\s*['"](.*?)['"]/, 1 ]
    end

    def shell
      'bash --login'
    end

    private

    attr_accessor :deploy_info, :stage

    def load_deploy_info
      self.deploy_info = ''

      if stage
        deploy_info << File.read(File.join root, "config/deploy/#{ stage }.rb")
        deploy_info << "\n"
      end

      deploy_info << File.read(File.join root, 'config/deploy.rb')
    end

    def find_project_root!
      current = Dir.pwd
      until File.exists?('Capfile')
        Dir.chdir '..'
        raise <<-ERROR if current == Dir.pwd
Could not locate Capfile.

Are you calling me from within a Rails project?
Maybe Capistrano is not installed in this project.
        ERROR

        current = Dir.pwd
      end
      current
    end

    def credentials
      @credentials ||= begin
        region                = ENV['AWS_REGION']
        aws_access_key_id     = ENV['AWS_ACCESS_KEY_ID']
        aws_secret_access_key = ENV['AWS_SECRET_ACCESS_KEY']
        raise <<-ERROR if region.nil? || aws_access_key_id.nil? || aws_secret_access_key.nil?
Please export AWS security credentials into your current shell session!
AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
        ERROR

        Aws::Credentials.new(aws_access_key_id, aws_secret_access_key)
      end
    end

    def region
      @region ||= ENV['AWS_REGION']
    end

  end
end
