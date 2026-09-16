# aws-local

Ambiente local para emular a AWS com [Floci](https://floci.io/aws/), usado para
desenvolver/testar a arquitetura **FlowQueue** (ver `docs/flowqueue.md`)
sem precisar de uma conta AWS real.

## Pré-requisitos

- [Docker](https://docs.docker.com/get-docker/) — o Floci roda em container e também
  sobe outros containers reais para simular alguns serviços (Lambda, RDS,
  ElastiCache etc.), então precisa do socket do Docker do host.
- [Terraform](https://developer.hashicorp.com/terraform/install) `>= 1.5` — só
  necessário se for provisionar a arquitetura FlowQueue (ver `terraform/versions.tf`).
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
  — opcional, para interagir manualmente com o Floci.

## Quick start

```bash
cp .env.example .env
make up          # sobe o Floci em http://localhost:4566
export $(grep -v '^#' .env | xargs)

aws s3 mb s3://my-bucket
aws sqs create-queue --queue-name orders
```

Para provisionar a arquitetura FlowQueue completa via Terraform (ver
`terraform/README.md` para detalhes, apply incremental e limitações
conhecidas do Floci):

```bash
make tf-init
make tf-plan
make tf-apply
```

Outros comandos:

```bash
make logs        # acompanhar logs
make ps           # ver status do container
make sh           # shell dentro do container
make restart      # down + up
make down         # parar
make reset        # parar e apagar todo o estado persistido (data/)

make tf-init      # terraform init (dentro de terraform/)
make tf-plan      # terraform plan   -var-file=environments/local/terraform.tfvars
make tf-apply     # terraform apply  -var-file=environments/local/terraform.tfvars
make tf-destroy   # terraform destroy -var-file=environments/local/terraform.tfvars
```

## Estrutura

- `docker-compose.yml` — sobe o Floci (imagem, portas, volumes, storage mode).
- `.env.example` — variáveis de ambiente da AWS CLI/SDK e do container Floci.
- `init/` — scripts opcionais executados na subida do container (criação automática de recursos).
- `data/` — estado persistido pelo Floci (ignorado no git).
- `terraform/` — código Terraform modular que provisiona a arquitetura FlowQueue (ver `terraform/README.md`).
- `docs/floci.md` — documentação de referência do emulador Floci.
- `docs/flowqueue.md` — documentação da arquitetura FlowQueue (desenho original/base).
- `docs/arquitetura-completa.md` — a mesma arquitetura com borda protegida, autenticação, VPC Endpoints, escala por demanda real e observabilidade.
- `docs/terraform.md` — explicação do código Terraform (`terraform/`): estrutura, o que cada módulo provisiona e como main.tf conecta tudo.
- `docs/melhorias.md` — plano de melhorias pendentes na arquitetura FlowQueue.
- `docs/diagrams/` — diagramas da arquitetura (`.drawio` + `.png`).
- `docs/backend-idempotencia.md`, `docs/frontend-auth.md`, `docs/dns-validacao.md` — contratos/passos manuais complementares às melhorias implementadas (ver `docs/melhorias.md`).

## Limitações e próximos passos

O Floci tem algumas lacunas de compatibilidade validadas na prática (ex:
CloudFront quebra o provider da AWS, `CreateListener` do ELBv2 retorna 500)
— contornos e detalhes em `terraform/README.md`. Melhorias planejadas para a
própria arquitetura FlowQueue (idempotência, scaling, WAF/HTTPS etc.) estão
descritas em `docs/melhorias.md`.
