require 'erb'
require 'oca'

require 'one.rb'
require 'opennebulahelper.rb'

class ScalarisHelper < OpenNebulaHelper
  def get_master_description()
    description = get_description(SCALARISIMAGE, "true", "",
                                  "{mgmt_server, {{127,0,0,1},14195,mgmt_server}}.")
    puts description
    description
  end

  def get_slave_description(ips, head_node)
    mgmt_server = "{mgmt_server, {{#{head_node.gsub(/\./, ',')}}, 14195, mgmt_server}}."
    description = get_description(SCALARISIMAGE, "false", ips, mgmt_server)
    puts description
    description
  end

  def remove(num, instance)
    [false, "Not yet implemented"]
  end

  def get_node_info(instance, vmid)
    info = {}
    info[:rpm_version] = get_scalaris_version()
    info.merge!(get_scalaris_info("get_node_info"))
    info
  end

  def get_node_performance(instance, vmid)
    perf = {}
    info.merge!(get_scalaris_info("get_node_performance"))
    perf
  end

  def get_service_info(instance)
    info = {}
    info[:rpm_version] = get_scalaris_version()
    info.merge!(get_scalaris_info("get_service_info"))
    info
  end

  def get_service_performance(instance)
    perf = {}
    info.merge!(get_scalaris_info("get_service_performance"))
    perf
  end

  private

  def get_scalaris_info(call)
    url = "http://localhost:8000/jsonrpc.yaws"
    JSONRPC.json_call(url, "get_node_info", [])["result"]["value"]
  end

  def get_scalaris_version()
    result = %x[rpm -q scalaris-svn --qf "%{VERSION}"]
    result.to_s
  end

  def get_description(image, scalarisfirst, ips, mgmt_server)
    @image = image
    @scalarisfirst = scalarisfirst
    @known_hosts = render_known_hosts(ips)
    @mgmt_server = mgmt_server
    erb = ERB.new(File.read("scalaris.one.vm.erb"))
    erb.result binding
  end

  def render_known_hosts(ips)
    nodes = ips.map {|ip|
      "{{#{ip.gsub(/\./, ',')}}, 14195, service_per_vm}"
    }.join(", ")
    "{known_hosts, [#{nodes}]}."
  end
end
