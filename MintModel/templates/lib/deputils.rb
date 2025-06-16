require 'net/smtp'
require 'tempfile'
require 'net/ssh'


######### COMMON METHODS ###################
# This function will return true if evaluated on ocloud
def on_cloud?(dns)
  if dns and dns['zone']=='limepoint.engineering'
    return true
  else
    return false
  end
end

def is_running_on_cloud()
  unless defined?(@vars)
    # template(erb)
    dns = self.instance_variable_get("@dns".to_sym)
    on_cloud?(dns)
  else
    # business_rules
    dns = @vars['dns']
    on_cloud?(dns)
  end
end

###### METHODS THAT DEPEND ON DSL ######################
def wait_for_server_complete(my_item, child_item, server_name, stage, vars)
  dsl.mintpress_executeitem "check-#{my_item}-#{child_item}-#{server_name}-#{stage}" do
    asset "#{my_item}"
    server 'AdminServer'
    perform_when "pre-#{stage}"
    value "LOOP=1 ; while [ $LOOP != 0 ]; do timeout 1 bash -c 'cat < /dev/null > /dev/tcp/#{vars[child_item][server_name]['listen_address']}#{vars[child_item]['dns_domain_name']}/#{vars[child_item][server_name]['listen_port'].to_s}' ; LOOP=$? ; echo 'contacting #{vars[child_item][server_name]['listen_address']}#{vars[child_item]['dns_domain_name']}/#{vars[child_item][server_name]['listen_port'].to_s}' ; sleep 1 ;  done"
  end
end

# wait for all listen ports of a service to be available
def wait_for_asset_complete(my_item, child_item, stage, vars)
  vars[child_item.downcase].each do |k, v|
    if v.is_a?(Hash) and v['listen_address'] and k != 'frontend'
      wait_for_server_complete(my_item, child_item, k, stage, vars)
    end
  end
end

def wait_for_databases()
  ['online', 'start'].each do |stage|
    dsl.mintpress_executeitem "ensure-db-working-#{stage}" do
      asset "global"
      server 'AdminServer'
      perform_when "pre-#{stage}"
      value "export ORACLE_HOME=/oracle/stage/sqlplus/client/11.2.0/ ; export LD_LIBRARY_PATH=$ORACLE_HOME/lib ; export PATH=$PATH:$ORACLE_HOME/bin ; $(out='' ; dbs=getkey(fulldata, 'site.resourceList.JDBCSystemResource.params.JDBCResource.params.JDBCDriverParams') ; if dbs.is_a?(Hash) then dbs=[dbs] end ; dbs.each { |d| if d['properties'] and d['properties']['user'] and d['attributes'] and d['attributes']['Password'] and d['attributes']['Url'] then out+=\"RESULT=1 ; while [ $RESULT != 0 ]; do sqlplus '\"+d['properties']['user']+\"/\"+Mint::AesEncryption.decrypt(resolveInternalFull(d['attributes']['Password'], fulldata))+d['attributes']['Url'].gsub('jdbc:oracle:thin:','') +\"' </dev/null 2>&1 | grep 'Connected.to' ; RESULT=$? ; if [ $RESULT != 0 ]; then sleep 5 ; fi ; done ; \" end } ; out+=\" /bin/true\")"
    end
  end
end

def wait_for_authenticators()
  ['online', 'start'].each do |stage|
    dsl.mintpress_executeitem "ensure-oid-working-#{stage}" do
      asset "global"
      server 'AdminServer'
      perform_when "pre-online"
      value "$(out='' ; auths=getkey(fulldata, 'site.resourceList.AuthenticationProvider.attributes') ; if auths.nil? then auths=[] ; end ; if !auths.is_a?(Array) then auths=[auths]; end ; auths.each { |d| if d['Host'] and d['Port'] then out+=\"LOOP=1 ; while [ $LOOP != 0 ]; do timeout 1 bash -c 'cat < /dev/null > /dev/tcp/\"+d['Host']+\"/\"+d['Port'].to_s+\"' ; LOOP=$? ; echo 'contacting \"+d['Host']+d['Port'].to_s+\"' ; sleep 1 ;  done ; \" end } ; out+=\" /bin/true\")"
    end
  end
end

def build_deps(topology_vars, asset_code)
  puts "deputils: build_deps"
  wait_for_authenticators()
  if asset_code == 'obpohs' || asset_code == 'obpotd'
    puts "No DB Dependency for asset obpohs/obpotd"
  else
    wait_for_databases()
  end
  ## From romil's notes:
  # Run SOA Offline
  # Run Host Offline, Online
  # 5. Run SOA online, UI online

  ## At least some of these are probably taken care of else where, but we put them hre
  ## because we needed them before!

  # CIM requires CID to complete for offline stage
  wait_for_asset_complete('obpcim', 'obpcid', 'configure', topology_vars)

  # OSB Online Requires Host RCU
  wait_for_server_complete('obposb', 'obpobh', 'admin', 'configure', topology_vars)

  # BIP Online Requires Host RCU
  wait_for_server_complete('obpbip', 'obpobh', 'admin', 'configure', topology_vars)

  # ODI Online Requires Host RCU
  wait_for_server_complete('obpodi', 'obpobh', 'admin', 'configure', topology_vars)

  # UI Online Requires Host RCU
  wait_for_server_complete('obpobu', 'obpobh', 'admin', 'configure', topology_vars)

  # Host requires SOA offline to have run to policy re-association
  wait_for_server_complete('obpobh', 'obpsoa', 'admin', 'configure', topology_vars)

  # UI requires SOA offline to have run to policy re-association
  wait_for_server_complete('obpobu', 'obpsoa', 'admin', 'configure', topology_vars)

  # OHS Online Requires OAM Server To Be ready
  wait_for_server_complete('obpohs', 'obpoam', 'oam_server', 'online', topology_vars)

  # OAM Offline Requires OID Completion
  wait_for_asset_complete('obpoam', 'obpoid', 'online', topology_vars)
end

