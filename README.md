# aws-local

Ambiente local para emular a AWS com [Floci](https://floci.io/aws/), usado para
desenvolver/testar a arquitetura **FlowQueue** (ver `flowqueue-tf/docs/flowqueue.md`)
sem precisar de uma conta AWS real.

## Quick start

```bash
cp .env.example .env
make up          # sobe o Floci em http://localhost:4566
export $(grep -v '^#' .env | xargs)

aws s3 mb s3://my-bucket
aws sqs create-queue --queue-name orders
```

Outros comandos:

```bash
make logs        # acompanhar logs
make ps           # ver status do container
make sh           # shell dentro do container
make down         # parar
make reset        # parar e apagar todo o estado persistido (data/)
```

## Estrutura

- `docker-compose.yml` — sobe o Floci (imagem, portas, volumes, storage mode).
- `.env.example` — variáveis de ambiente da AWS CLI/SDK e do container Floci.
- `init/` — scripts opcionais executados na subida do container (criação automática de recursos).
- `data/` — estado persistido pelo Floci (ignorado no git).
- `flowqueue-tf/` — código Terraform modular que provisiona a arquitetura FlowQueue (ver `flowqueue-tf/README.md`).
- `flowqueue-tf/docs/floci.md` — documentação de referência do emulador Floci.
- `flowqueue-tf/docs/flowqueue.md` — documentação da arquitetura FlowQueue.
- `flowqueue-tf/docs/flowqueue-arquitetura.drawio` — diagrama da arquitetura.
