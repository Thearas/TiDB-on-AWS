PRIV_KEY:=tidb.pem
PUB_KEY:=tidb.pem.pub
TIDB_CLUSTER_VERSION:=v4.0.9

gen_key_pair:
	@ssh-keygen -q -N "" -t ed25519 -f ${PRIV_KEY} <<<y 2>&1 >/dev/null

build: gen_key_pair
	jsonnet --ext-str-file TiDBClusterPrivateKey=${PRIV_KEY} --ext-str-file TiDBClusterPublicKey=${PUB_KEY} --ext-str TiDBClusterVersion=${TIDB_CLUSTER_VERSION} -m . main.jsonnet
