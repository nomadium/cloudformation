require 'fog'
require 'pp'
require 'docopt'
require 'octokit'
require 'base64'
require 'pry'

doc = <<DOCOPT
Launch something in a VPC.

Usage:
  #{__FILE__} [options]

Options:
  -h, --help                     Show this.
  -N, --name NAME                Name of the AWS CloudFormation stack to be launched.
  -r, --region REGION            AWS region where to launch resources [default: us-west-2].
  -c, --credential CREDENTIAL    Fog library credential set to use with AWS services [default: default].
  -b, --bucket_pattern PATTERN   Naming pattern to use with temporal AWS S3 bucket to upload templates [default: miguel-bucket].
  -k, --keyname_pattern PATTERN  Naming pattern for SSH keypair to be create to connect to EC2 instances. [default: miguel-key].
  -u, --user USERNAME            Github username of the account where are stored the templates [default: nomadium].
  -R, --repository REPO_NAME     Git repository name [default: cloudformation].
  -p, --path REPO_NAME           Path of the template files inside the repository [default: templates].
  -t, --trusted CIDR_BLOCK       Trusted location CIDR block [default: 186.22.226.72/32].
  -v, --verbose                  Verbose [default: false].

Example:
  #{__FILE__} --name foo --trusted 169.254.169.254/32 --verbose

DOCOPT

def parse_parameters(opts)
  opts.keys.each do |k|
    opts[k.gsub(/^--/, '').to_sym] = opts[k]
    opts.delete(k)
  end
  opts
end

def create_temporal_bucket(opts={})
  o = {
    :region            => nil,
    :bucket_pattern    => nil
  }.merge opts
  %w(region bucket_pattern).each do |p|
    raise ArgumentError, "#{p} can't be nil!" unless o[p.to_sym]
  end
  s3_conn = Fog::Storage.new({
    :provider => 'AWS',
    :region   => o[:region]
  })
  bucket = s3_conn.directories.create(
    :key => "#{o[:bucket_pattern]}-#{Time.now.strftime '%Y%m%d%H%M'}"
  )
  bucket
end

def create_ec2_ssh_keypair(opts={})
  o = {
    :region          => nil,
    :keyname_pattern => nil
  }.merge opts
  %w(region keyname_pattern).each do |p|
    raise ArgumentError, "#{p} can't be nil!" unless o[p.to_sym]
  end
  ec2_conn = Fog::Compute.new(
    :provider => 'AWS',
    :region   => o[:region]
  )
  ec2_key_response = ec2_conn.create_key_pair "#{o[:keyname_pattern]}-#{Time.now.strftime '%Y%m%d%H%M'}"
  raise unless ec2_key_response.status.eql? 200 
  {
    :key_name        => ec2_key_response.data[:body]['keyName'],
    :key_material    => ec2_key_response.data[:body]['keyMaterial'],
    :key_fingerprint => ec2_key_response.data[:body]['keyFingerprint']
  }
end

def upload_template(opts={})
  o = {
    :user       => nil,
    :repository => nil,
    :path       => nil,
    :bucket     => nil
  }.merge opts
  %w(user repository path bucket).each do |p|
    raise ArgumentError, "#{p} can't be nil!" unless o[p.to_sym]
  end
  client = Octokit::Client.new
  template_resource = client.contents "#{o[:user]}/#{o[:repository]}", :path => o[:path]
  template_s3 = o[:bucket].files.create(
    :key  => o[:path],
    :body => Base64.decode64(template_resource.attrs[:content])
  )
  template_s3
end

def get_template_url(opts={})
  o = {
    :template => nil,
    :bucket   => nil
  }.merge opts
  #foo_stack = bucket.files.new(:key => 'foo.template')
  url = o[:bucket].files.get_http_url o[:template].key, Time.now.to_i + 3600
  uri = URI url
  uri.query = nil
  url = uri.to_s
  url
end

def create_stack(opts={})
  o = {
    :region            => nil,
    :template_url      => nil,
    :stack_name        => nil,
    :disable_rollback  => false,
    :notification_arns => [],
    :parameters        => {},
    :timeout           => 60,
    :capabilities      => []
  }.merge opts
  %w(region stack_name template_url).each do |p|
    raise ArgumentError, "#{p} can't be nil!" unless o[p.to_sym]
  end

  cf_conn = Fog::AWS::CloudFormation.new :region => o[:region]

  validate_template_response = cf_conn.validate_template 'TemplateURL' => o[:template_url]
  raise unless validate_template_response.status.eql? 200

  create_stack_response = cf_conn.create_stack(
    stack_name = o[:stack_name],
    options = {
      'TemplateURL'      => o[:template_url],
      'DisableRollback'  => o[:disable_rollback],
      'NotificationARNs' => o[:notification_arns],
      'Parameters'       => o[:parameters],
      'TimeoutInMinutes' => o[:timeout],
      'Capabilities'     => o[:capabilities]
    }
  )
  raise unless create_stack_response.status.eql? 200
  create_stack_response
end

def cleanup(o, resources)
  binding.pry
  resources[:stacks].keys.each do |stack|
    resources[:stacks][stack][:template].destroy
  end  
  resources[:bucket].destroy

  ec2_conn = Fog::Compute.new :provider => 'AWS', :region => o[:region]
  response = ec2_conn.delete_key_pair resources[:keypair][:key_name]
  raise unless response.status.eql? 200

  cf_conn = Fog::AWS::CloudFormation.new :region => o[:region]
  response = cf_conn.delete_stack o[:name]
  raise unless response.status.eql? 200
end

begin
  options = Docopt::docopt doc
rescue Docopt::Exit => e
  puts e.message
end

options = parse_parameters options
pp options if options[:verbose]

Fog.credential = options[:credential]

bucket = create_temporal_bucket options
pp bucket.key if options[:verbose]

keypair = create_ec2_ssh_keypair options
puts "key name: #{keypair[:key_name]}"
puts "key file:\n#{keypair[:key_material]}"

stacks = {}
%w(vpc instance).each do |stack|
  template = upload_template(
    :user       => options[:user],
    :repository => options[:repository],
    :bucket     => bucket,
    :path       => "#{options[:path]}/#{stack}.template"
  )
  stacks[stack.to_sym] = {
    :template => template,
    :url      => get_template_url(:template => template, :bucket => bucket)
  }
end

stack_response = create_stack(
  :region            => options[:region],
  :stack_name        => options[:name],
  :template_url      => stacks[:instance][:url],
  :parameters        => {
    'VPCStackURL'      => stacks[:vpc][:url],
    'TrustedCidrBlock' => options[:trusted],
    'KeyName'          => keypair[:key_name]
  },
  :capabilities      => ['CAPABILITY_IAM']
)
p stack_response

cleanup options, {:bucket => bucket, :keypair => keypair, :stacks => stacks}
