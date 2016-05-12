def debug_packages(packages)
  packages.map { |x| x + debug_ext }
end

def debug_ext
  case node['platform_family']
  when 'debian'
    '-dbg'
  when 'rhel', 'fedora'
    '-debug'
  else
    ''
  end
end

def cephfs_requires_fuse
  # What kernel version supports the given Ceph version tunables
  # http://ceph.com/docs/master/rados/operations/crush-map/
  min_versions = {
    'argonaut' => 3.6,
    'bobtail' => 3.9,
    'cuttlefish' => 3.9,
    'dumpling' => 3.9,
    'emperor' => 3.9,
    'firefly' => 3.15,
    'giant' => 3.15,
    'hammer' => 4.1,
    'jewel' => 4.5,
  }
  min_versions.default = 3.15

  # If we are on linux and have a new-enough kernel, allow kernel mount
  if node['os'] == 'linux' && Gem::Version.new(node['kernel']['release'].to_f) >= Gem::Version.new(min_versions[node['ceph']['version']])
    false
  else
    true
  end
end

def ceph_exactversion(pkg)
  pkg_ver = nil
  if node['ceph']['exactversion'] then
    if node['ceph']['exactversion'].respond_to?(:has_key?) then
      pkg_ver = node['ceph']['exactversion']['default'] if node['ceph']['exactversion'].has_key?('default')
      pkg_ver = node['ceph']['exactversion'][pkg] if node['ceph']['exactversion'].has_key?(pkg)
    else
      pkg_ver = node['ceph']['exactversion']
    end
  end
end
