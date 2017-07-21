# This recipe creates a monitor cluster
#
# You should never change the mon default path or
# the keyring path.
# Don't change the cluster name either
# Default path for mon data: /var/lib/ceph/mon/$cluster-$id/
#   which will be /var/lib/ceph/mon/ceph-`hostname`/
#   This path is used by upstart. If changed, upstart won't
#   start the monitor
# The keyring files are created using the following pattern:
#  /etc/ceph/$cluster.client.$name.keyring
#  e.g. /etc/ceph/ceph.client.admin.keyring
#  The bootstrap-osd and bootstrap-mds keyring are a bit
#  different and are created in
#  /var/lib/ceph/bootstrap-{osd,mds}/ceph.keyring

node.default['ceph']['is_mon'] = true

include_recipe 'ceph'
include_recipe 'ceph::mon_install'

service_type = node['ceph']['mon']['init_style']

directory '/var/run/ceph' do
  owner node['ceph']['owner']
  group node['ceph']['group']
  mode 00755
  recursive true
  action :create
end

directory "/var/lib/ceph/mon/ceph-#{node['hostname']}" do
  owner node['ceph']['owner']
  group node['ceph']['group']
  mode 00755
  recursive true
  action :create
end

# TODO: cluster name
cluster = 'ceph'

keyring = "#{node['ceph']['mon']['keyring_path']}/#{node['ceph']['cluster']}.mon.keyring"

execute 'format mon-secret as keyring' do # ~FC009
  command lazy { "ceph-authtool '#{keyring}' --create-keyring --name=mon. --add-key='#{mon_secret}' --cap mon 'allow *'" }
  creates keyring
  user node['ceph']['owner']
  group node['ceph']['group']
  only_if { mon_secret }
  sensitive true if Chef::Resource::Execute.method_defined? :sensitive
end

execute 'generate mon-secret as keyring' do # ~FC009
  command "ceph-authtool '#{keyring}' --create-keyring --name=mon. --gen-key --cap mon 'allow *'"
  creates keyring
  user node['ceph']['owner']
  group node['ceph']['group']
  not_if { mon_secret }
  notifies :create, 'ruby_block[save mon_secret]', :immediately
  sensitive true if Chef::Resource::Execute.method_defined? :sensitive
end

execute 'add bootstrap-osd key to keyring' do
  command lazy { "ceph-authtool '#{keyring}' --name=client.bootstrap-osd --add-key='#{osd_secret}' --cap mon 'allow profile bootstrap-osd'  --cap osd 'allow profile bootstrap-osd'" }
  only_if { node['ceph']['encrypted_data_bags'] && osd_secret }
end

ruby_block 'save mon_secret' do
  block do
    fetch = Mixlib::ShellOut.new("ceph-authtool '#{keyring}' --print-key --name=mon.")
    fetch.run_command
    key = fetch.stdout
    node.set['ceph']['monitor-secret'] = key
    node.save
  end
  action :nothing
end

execute 'ceph-mon mkfs' do
  command "ceph-mon --mkfs -i #{node['hostname']} --keyring '#{keyring}'"
  user node['ceph']['owner']
  group node['ceph']['group']
end

ruby_block 'finalise' do
  block do
    ['done', service_type].each do |ack|
      ::File.open("/var/lib/ceph/mon/ceph-#{node['hostname']}/#{ack}", 'w').close
    end
  end
end

if service_type == 'upstart'
  service 'ceph-mon' do
    provider Chef::Provider::Service::Upstart
    action :enable
  end
  service 'ceph-mon-all' do
    provider Chef::Provider::Service::Upstart
    supports :status => true
    action [:enable, :start]
  end
end

service 'ceph_mon' do
  case service_type
  when 'upstart'
    service_name 'ceph-mon-all-starter'
    provider Chef::Provider::Service::Upstart
  else
    service_name 'ceph'
  end
  supports :restart => true, :status => true
  action [:enable, :start]
end

until 'mon admin socket ready' do
  command '/bin/false'
  wait_interval 5
  message 'sleeping for 5 seconds and retrying'
  action :run
end

mon_addresses.each do |addr|
  execute "#{addr}" do
    command "ceph --admin-daemon '/var/run/ceph/ceph-mon.#{node['hostname']}.asok' add_bootstrap_peer_hint #{addr}"
    retries 5
    ignore_failure true
  end
end

# Create a new bootstrap-osd secret key if it does not exist either on disk as node attribtues
bash 'create-bootstrap-osd-key' do
  code <<-EOH
    BOOTSTRAP_KEY=$(ceph --name mon. --keyring /etc/ceph/#{node['ceph']['cluster']}.mon.keyring auth get-or-create-key client.bootstrap-osd mon 'allow profile bootstrap-osd')
    ceph-authtool "/var/lib/ceph/bootstrap-osd/#{node['ceph']['cluster']}.keyring" \
        --create-keyring \
        --name=client.bootstrap-osd \
        --add-key="$BOOTSTRAP_KEY"
  EOH
  only_if "test -s /etc/ceph/#{node['ceph']['cluster']}.mon.keyring"
  not_if { node['ceph']['bootstrap_osd_key'] }
  not_if "test -s /var/lib/ceph/bootstrap-osd/#{node['ceph']['cluster']}.keyring"
  notifies :create, 'ruby_block[save_bootstrap_osd]', :immediately
  sensitive true if Chef::Resource::Execute.method_defined? :sensitive
end

# If the bootstrap-osd secret key exists as a node attribute but not on disk, write it out
execute 'format bootstrap-osd-secret as keyring' do
  command lazy { "ceph-authtool '/var/lib/ceph/bootstrap-osd/#{node['ceph']['cluster']}.keyring' --create-keyring --name=client.bootstrap-osd --add-key=#{ceph_chef_bootstrap_osd_secret}" }
  only_if { node['ceph']['bootstrap_osd_key'] }
  not_if "test -s /var/lib/ceph/bootstrap-osd/#{node['ceph']['cluster']}.keyring"
  sensitive true if Chef::Resource::Execute.method_defined? :sensitive
end

# If the bootstrap-osd secret key exists on disk but not as a node attribute, save it as an attribute
ruby_block 'check_bootstrap_osd' do
  block do
    true
  end
  notifies :create, 'ruby_block[save_bootstrap_osd]', :immediately
  not_if { node['ceph']['bootstrap_osd_key'] }
  only_if "test -s /var/lib/ceph/bootstrap-osd/#{node['ceph']['cluster']}.keyring"
end

# Save the bootstrap-osd secret key to the node attributes. This is typically performed
# as a notification following the create step, but you can set:
#   node['ceph']['monitor-secret'] = ceph_chef_keygen()
# in a higher level recipe to force a specific value
ruby_block 'save_bootstrap_osd' do
  block do
    fetch = Mixlib::ShellOut.new("ceph-authtool '/var/lib/ceph/bootstrap-osd/#{node['ceph']['cluster']}.keyring' --print-key --name=client.bootstrap-osd")
    fetch.run_command
    key = fetch.stdout
    node.normal['ceph']['bootstrap-osd'] = key.delete!("\n")
  end
  action :nothing
end
