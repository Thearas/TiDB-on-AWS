(import 'cfn_tidb.libsonnet') +
{
  'cfn_tidb_params.yaml': {
    TiDBClusterPrivateKey: std.extVar('TiDBClusterPrivateKey'),
    TiDBClusterPublicKey: std.extVar('TiDBClusterPublicKey'),
  },

  'cfn_tidb.yaml':
    local tidbCluster = $.tidb.new().withComponents([
      $.tidb.component.new('PD').replicas(2).instantType('a1.medium'),
      $.tidb.component.new('TiDB').replicas(3).instantType('a1.medium'),
      $.tidb.component.new('TiKV').replicas(3).instantType('a1.medium'),
    ]);
    tidbCluster.buildWithTestServer('a1.medium'),
}
