# init/

Scripts colocados aqui são executados automaticamente pelo Floci na subida do
container (compatível com `/etc/localstack/init` do LocalStack).

Use para criar recursos automaticamente ao subir o ambiente (buckets, filas,
tabelas, etc.), por exemplo:

```bash
#!/usr/bin/env bash
# init/01-setup.sh
awslocal sqs create-queue --queue-name orders
awslocal dynamodb create-table \
  --table-name orders \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

- Scripts `.sh` precisam de permissão de execução (`chmod +x init/01-setup.sh`).
- São executados em ordem alfabética.
- Se usar `awslocal`/`aws`/`boto3` dentro dos scripts, defina no `.env`:
  `FLOCI_IMAGE=floci/floci:latest-compat` (imagem com AWS CLI e boto3 embutidos).
