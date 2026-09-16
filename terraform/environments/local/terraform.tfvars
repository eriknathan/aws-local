# Valores para rodar contra o Floci local (docker-compose.yml na raiz do repo).
# Nenhum segredo real aqui — seguro pra commitar.

aws_region         = "us-east-1"
use_local_endpoint = true
aws_endpoint_url   = "http://localhost:4566"
aws_access_key     = "admin-local-aws"
aws_secret_key     = "admin-local-aws"

# Placeholders — ajuste conforme o mapeamento de AMI que o Floci esperar
# para os containers de EC2 (ver docs/floci.md, seção 2.3).
frontend_ami_id = "ami-0000000000000front"
backend_ami_id  = "ami-0000000000000back"

# O stub de CloudFront do Floci hoje derruba o provider AWS (panic/nil
# pointer em flattenDefaultCacheBehavior logo após o create). Desabilitado
# aqui até o Floci evoluir o suporte; o ALB já cobre a borda pública.
enable_cloudfront = false

# O CreateListener do ELBv2 no Floci retorna 500 (InternalFailure) de forma
# determinística — reproduzido até via AWS CLI puro, sem Terraform. O
# target group já existe e o Frontend já é anexado a ele; só o listener HTTP
# fica de fora até o Floci corrigir.
enable_alb_listener = false
