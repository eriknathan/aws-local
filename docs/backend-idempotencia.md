# Idempotência do Backend (S3 + DynamoDB + SQS)

Referente ao item 1 de `melhorias.md`. Fila principal continua **SQS standard**
(throughput maior); a deduplicação de reentregas é responsabilidade da lógica
abaixo, implementada pelo Backend — não há recurso de fila FIFO neste repo.

## Problema

O Backend pode subir o recibo no S3 e falhar antes de gravar o DynamoDB (ou
vice-versa), deixando estado inconsistente. Reentregas da SQS (retry após
`visibility_timeout`, falha de rede, etc.) podem gerar recibos duplicados —
cada `PutObject` cria uma versão nova no bucket, retida por
`var.receipts_retention_days` (365 dias por padrão) por causa do Object Lock.

## Fluxo que o Backend precisa seguir

1. Recebe a mensagem da fila principal, extrai `order_id` (chave de
   idempotência).
2. Consulta o DynamoDB por `order_id` **antes** de tocar no S3. Se já existe
   um registro com `status = "RECEIPT_STORED"`, pula direto para o passo 4 —
   evita gerar uma versão nova no S3 numa reentrega.
3. Caso contrário: `PutObject` no S3 com chave determinística
   (`orders/<order_id>/receipt.pdf`), depois `UpdateItem` condicional no
   DynamoDB (`attribute_not_exists(receipt_version_id)` ou checagem de
   `status`) gravando `receipt_key` + `receipt_version_id` + `status`.
4. Só então chama `DeleteMessage` na fila.

Se o processo cair entre os passos 3 e 4, a mensagem volta a ficar visível
após `visibility_timeout_seconds` e é reprocessada — o passo 2 evita
reprocessar o S3 à toa nesse reprocessamento.

## O que já está em Terraform

- `terraform/modules/messaging/variables.tf`: `visibility_timeout_seconds`
  (default `90s`) — exposto na raiz como
  `var.sqs_visibility_timeout_seconds` (`terraform/variables.tf`) e passado
  ao módulo em `terraform/main.tf` (`module "messaging"`). Precisa ficar
  acima do pior caso de tempo de processamento do passo 2+3 (consulta
  DynamoDB + upload S3 + `UpdateItem`); ajuste via `-var` ou no
  `terraform.tfvars` do ambiente se o Backend demorar mais que isso na
  prática.
- Nenhum recurso novo de dados — o DynamoDB já é schemaless o suficiente
  para os atributos extras (`receipt_key`, `receipt_version_id`, `status`).

## O que não está em Terraform

O fluxo dos passos 1–4 é lógica de aplicação (código do Backend), fora do
escopo deste repositório — este documento é a referência de contrato que
qualquer implementação futura do Backend precisa seguir.
