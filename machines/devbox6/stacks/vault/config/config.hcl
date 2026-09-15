# Full configuration options can be found at
# https://www.vaultproject.io/docs/configuration
ui = true

# This is the physical backend that Vault uses for storage.
storage "file" {
  path = "/vault/file-storage/"
}

# HTTPS listener
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = 1
# tls_cert_file = "/vault/tls/aswernikus.my-new-site.com-fullchain.crt"
# tls_key_file  = "/vault/tls/aswernikus.my-new-site.com.key"
}

# use real local address from AWS machine
api_addr = "http://127.0.0.1:8200"
#cluster_addr = "https://127.0.0.1:8201"