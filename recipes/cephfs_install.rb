include_recipe 'ceph'

node['ceph']['cephfs']['packages'].each do |pck|
  package pck do
    action node['ceph']['package_action']
    v = ceph_exactversion(pck)
    version v if v
  end
end

# Update the fuse.ceph helper for pre-firefly
remote_file '/sbin/mount.fuse.ceph' do
  source 'https://raw.githubusercontent.com/ceph/ceph/master/src/mount.fuse.ceph'
  only_if { ::File.exist?('/sbin/mount.fuse.ceph') }
  not_if { ::File.readlines('/sbin/mount.fuse.ceph').grep(/_netdev/).any? }
end
