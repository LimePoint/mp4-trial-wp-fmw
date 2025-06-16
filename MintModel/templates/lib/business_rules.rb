require_relative 'deputils'
require 'environmint-model-utils/mintpressdsl'
require 'json'

################ WA #########################
class Node
  def initialize
    # Initialize run_state with the desired key-value pair
    @run_state = {'orchestration_metadata' => {'launchDetails' => {'environment' => {'name' => 'p1'}}}, 'OBPSOA' => true, 'OBPOSB' => false, 'OBPIPM' => false, 'OBPOHS' => true, 'OBPOTD' => true, 'mintpress_action' => 'upload'}
  end

  def run_state
    @run_state
  end
end
################ WA #########################

class DSLProcessor

  attr_accessor :dsl, :asset_code, :vars

  def initialize(asset_code, vars)
    @asset_code = asset_code
    @vars = vars
    @dsl = MintPress::MintPressDSL.new
  end

  def asset_code
    @asset_code
  end

  def dsl
    @dsl
  end

  def vars
    @vars
  end

##### process_rules ###########
  def process_rules
    asset_code = asset_code()
    vars = vars()

####### WA ########
    node = Node.new
####### WA #######

    dsl.mintpress_resource "coherence-config" do
      asset asset_code
      type "CoherenceListen"
      value "%LISTENNAME%-prv#{vars[asset_code]['dns_domain_name']}"
      only_if { asset_code != 'obpsoa' }
    end

    dsl.mintpress_resource "coherence-config" do
      asset asset_code
      type "CoherenceListen"
      value "%LISTENNAME%#{vars[asset_code]['dns_domain_name']}"
      only_if { asset_code == 'obpsoa' or asset_code == 'obpoim' }
    end

    dsl.mintpress_startup_parameter "coherence-start" do
      asset asset_code
      server "ODI_server*"
      parameters ["%WKAodi-2000%"]
    end

    dsl.mintpress_startup_parameter "coherence-startup" do
      asset asset_code
      server "*osb_server*"
      parameters ["%WKAosb-2000%"]
      only_if { asset_code == 'obposb' }
    end

    dsl.mintpress_startup_parameter "coherence-startup" do
      asset asset_code
      server "*soa_server*"
      parameters ["%WKAsoa-2000%"]
      only_if { asset_code == 'obpsoa' or asset_code == 'obpdoc' or asset_code == 'obpoim' }
    end

    # build_deps invoked from OBP_utils.rb
    env_name = vars['environment']['name']
    if is_running_on_cloud and !env_name.match('^och')
      build_deps(vars,asset_code)
    end

    if is_running_on_cloud
      dsl.mintpress_property "enable-exalogic-optimizations" do
        asset "global"
        tree "site.environmentList.*.mwTopologyList"
        name "targetPlatform"
        value "x86-64"
      end

      dsl.mintpress_property "disable-ext-network-channels" do
        asset "global"
        tree "site.resourceList.*ExtChanne*.attributes"
        name "Enabled"
        value "false"
      end

      dsl.mintpress_property "disable-ext-network-channels" do
        asset "global"
        tree "site.resourceList.wgchannel.attributes"
        name "Enabled"
        value "false"
      end

      if asset_code.downcase != 'obpotd' # do it for everything but otd as otd does not has db
        dsl.mintpress_property "disable-fan" do
          asset "global"
          tree "site.resourceList.JDBCSystemResource.params.JDBCResource.params.JDBCOracleParams.attributes"
          name "FanEnabled"
          only_existing true
          force_attribute true
          value "false"
        end

        dsl.mintpress_property "disable-ons" do
          asset "global"
          tree "site.resourceList.JDBCSystemResource.params.JDBCResource.params.JDBCOracleParams.attributes"
          name "OnsNodeList"
          only_existing true
          force_attribute true
          value "None"
        end
      end

      dsl.mintpress_property "all-in-parallel" do
        asset "global"
        tree "site.environmentList.*.mwTopologyList.*.domainList"
        name "mintpress.startup_parallel"
        value "8"
      end

      dsl.mintpress_executeitem "wait-rcu-ui" do
        asset "obpobu"
        server '*'
        perform_when "pre-rcu"
        value "RESULT=1 ; while [ $RESULT != 0 ]; do export ORACLE_HOME=/oracle/stage/sqlplus/client/11.2.0/ ; export LD_LIBRARY_PATH=$ORACLE_HOME/lib ; $ORACLE_HOME/bin/sqlplus OBPHOST_OBP/#{Mint::AesEncryption.decrypt(PasswordVault.get_password(env_name + '/' + 'obpobh', 'OBPHOST' ))}@${/databases.host.address}:${/databases.port}/${/databases.serviceName} </dev/null 2>&1 | grep Connected.to ; RESULT=$? ; sleep 5 ; done"
      end

      if asset_code != 'obpohs' and  asset_code != 'obpotd'
        dsl.mintpress_executeitem "check-db" do
          asset "global"
          server '*'
          perform_when "pre-rcu"
          value "RESULT=1 ; while [ $RESULT != 0 ]; do export ORACLE_HOME=/oracle/stage/sqlplus/client/11.2.0/ ; export LD_LIBRARY_PATH=$ORACLE_HOME/lib ; $ORACLE_HOME/bin/sqlplus llama/duck@${/databases.host.address}:${/databases.port}/${/databases.serviceName} </dev/null 2>&1 | grep logon.denied ; RESULT=$? ; sleep 5 ; done"
        end

        dsl.mintpress_executeitem "check-db-startup" do
          asset "global"
          server '*'
          perform_when "pre-start"
          value "RESULT=1 ; while [ $RESULT != 0 ]; do export ORACLE_HOME=/oracle/stage/sqlplus/client/11.2.0/ ; export LD_LIBRARY_PATH=$ORACLE_HOME/lib ; $ORACLE_HOME/bin/sqlplus llama/duck@${/databases.host.address}:${/databases.port}/${/databases.serviceName} </dev/null 2>&1 | grep logon.denied ; RESULT=$? ; sleep 5 ; done"
        end
      end

      # Ensure to run XA views on OIM and CIM Dbs
      dsl.mintpress_executeitem "xa-databases" do
        asset "obpoim,obpcim"
        value "cinc-client -l info -c ~/chef/client.rb -o obp-environmint-custom::create-xaviews"
        perform_when "pre-rcu"
      end

      # enable wildcard for internal engineering
      dsl.mintpress_property "nmwildcard" do
        asset "*"
        tree "site.environmentList.*.mwTopologyList.*.nodeManagerList.%NODEMANAGER%"
        name "wls.nodemanager.wildcardcertificate"
        value "true"
      end

      dsl.mintpress_mbean_config "serverconfig.ssl.wildcard" do
        asset "*"
        type "Server"
        propkey "serverName"
        param "SSL"
        keys Hash({
                      "HostnameVerifier" => "weblogic.security.utils.SSLWLSWildcardHostnameVerifier"
                  })
        server "*"
      end

      dsl.mintpress_startup_parameter "posixmuxer" do
        asset "global"
        server "*"
        parameters ["-Dweblogic.MuxerClass=weblogic.socket.PosixSocketMuxer"]
        matches ["-Dweblogic.MuxerClass=weblogic.socket.PosixSocketMuxer"]
      end

      dsl.mintpress_internal_variable "autoBaseline" do
        variable "autoBaseline"
        asset "global"
        value "true"
      end
    end #is_running_on_cloud

    # this is applicable for both onprem and ocloud
    dsl.mintpress_property "startup-managed-servers-in-parallel" do
      asset "global"
      tree "site.environmentList.*.mwTopologyList.*.domainList"
      name "mintpress.startup_parallel"
      value "10"
    end

    dsl.mintpress_property "startup-managed-servers-order" do
      asset "obpipm"
      tree "site.environmentList.*.mwTopologyList.*.domainList"
      name "mintpress.cluster_startup_order"
      value "*ucm*,*ipm*"
    end

    dsl.mintpress_property "startup-managed-servers-order" do
      asset "obpoim"
      tree "site.environmentList.*.mwTopologyList.*.domainList"
      name "mintpress.cluster_startup_order"
      value "*soa*,*oim*"
    end

    dsl.mintpress_property "startup-managed-servers-order" do
      asset "obpcim"
      tree "site.environmentList.*.mwTopologyList.*.domainList"
      name "mintpress.cluster_startup_order"
      value "*soa*,*oim*"
    end


    # Restart only SOA, OSB and IPM domains after a Rebuild or Provision.
    ['stopManagedBefore', 'stopAdminBefore', 'startAdminAfter', 'startManagedAfter'].each do |s|
      dsl.mintpress_property "add_restart_attr_#{s}" do
        tree "site.environmentList.*.mwTopologyList.*.executeList.FMW-Domain-Restart"
        name s
        value "true"
        only_if { ['provision', 'rebuild'].include? node.run_state['mintpress_action'] and (asset_code == 'obpsoa' or asset_code == 'obposb' or asset_code == 'obpipm') }
      end
    end

    puts "derived asset code : asset_code = #{asset_code.downcase}"
    dsl.mintpress_executeitem "force-kill-weblogic-server" do
      asset "global"
      value "echo '{ \"target_action\": \"managedserver\", \"target_asset_code\": \"#{asset_code.downcase}\" }' > /tmp/00.json && cinc-client -c $HOME/chef/client.rb -o 'recipe[obp-environmint-custom::force-kill-weblogic]' -l info -j /tmp/00.json"
      perform_when "post-managedserver-stop"
    end

    # return business rules
    dsl.items
  end
end
