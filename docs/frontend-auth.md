# API de status/download do recibo + autenticação (Frontend)

Referente ao item 6 de `melhorias.md`. Decisões confirmadas: a API é servida
pelo **Frontend existente** (não um componente novo), e há uma camada de
autenticação de usuário final via **Amazon Cognito** (escopo expandido em
relação ao plano original, que não incluía autenticação).

## O que já está em Terraform

- `terraform/modules/auth` (novo módulo): `aws_cognito_user_pool` (login por
  e-mail) + `aws_cognito_user_pool_client` sem secret (public client, pra um
  client SPA/mobile futuro autenticar via `InitiateAuth`).
- `terraform/main.tf`, `module "frontend"`: ganhou `dynamodb:GetItem` /
  `dynamodb:Query` na tabela de pedidos e `s3:GetObject` em
  `${module.storage.bucket_arn}/*` — só leitura, o bucket continua privado.
- IDs do User Pool/client e o `issuer_url` publicados no Parameter Store
  (`/flowqueue/auth/user-pool-id`, `/flowqueue/auth/user-pool-client-id`,
  `/flowqueue/auth/issuer-url`) via `module "parameters"`.

## O que NÃO está em Terraform (fora do escopo deste repo)

Não existe app code neste repositório — os itens abaixo são o contrato que
uma implementação futura do Frontend precisa seguir.

### Login do usuário

1. Cliente chama `InitiateAuth` (`USER_PASSWORD_AUTH` ou `USER_SRP_AUTH`)
   contra o User Pool, recebe `id_token` (JWT) + `refresh_token`.
2. `id_token` é enviado em `Authorization: Bearer <token>` nas chamadas
   subsequentes da API de status/download.

### Validação do JWT (a cada request)

1. Buscar (e cachear, com rotação) o JWKS em
   `<issuer_url>/.well-known/jwks.json` — `issuer_url` vem do Parameter
   Store acima.
2. Validar assinatura, `token_use = "id"`, `aud` = user pool client id, `iss`
   = `issuer_url`, e expiração.
3. O claim `sub` do token é o identificador do usuário — usado como
   `owner_id` (ver abaixo).

**Atenção ao rodar contra o Floci** (testado na prática): o `issuer_url`
publicado no Parameter Store vem do atributo `endpoint` do
`aws_cognito_user_pool`, que o Floci devolve no formato de AWS real
(`cognito-idp.us-east-1.amazonaws.com/<pool-id>`) — mas o `iss` real dentro
do `IdToken` emitido pelo Floci é `http://localhost:4566/<pool-id>`. Os dois
**não batem** localmente (devem bater contra a AWS real). Pra validar
localmente, use o `iss` que vem de dentro do próprio token (ou
`AWS_ENDPOINT_URL/<pool-id>`), não o `issuer_url` do Parameter Store — ver
`terraform/README.md` (seção de limitações do Floci).

### Rota de status/download (`GET /orders/<order_id>`, por exemplo)

1. Validar o JWT (acima). Sem token válido → `401`.
2. `dynamodb:GetItem` (ou `Query`) por `order_id`. Se não existir → `404`.
3. Comparar `owner_id` do registro com o `sub` do token. Se não bater →
   `403` (isso é o que a permissão `dynamodb:GetItem`/`Query` do Frontend
   viabiliza — sem ela não dá nem pra checar o dono).
4. Se `status != "RECEIPT_STORED"` (ver `backend-idempotencia.md`),
   devolver o status atual, sem URL.
5. Se `status == "RECEIPT_STORED"`: gerar uma URL pré-assinada de
   `GetObject` pra `receipt_key`, TTL curto (60–300s), e devolver. Essa é a
   única forma de acesso ao objeto — o bucket segue com
   `block_public_acls`/`restrict_public_buckets` habilitados
   (`terraform/modules/storage/main.tf`).

## Fora de escopo (por enquanto)

- **Hosted UI / tela de login do Cognito**: não foi criado
  `aws_cognito_user_pool_domain`. O app client autentica direto via
  `InitiateAuth`, sem redirect OAuth.
- **Autenticação nativa do ALB** (`authenticate-cognito` na listener rule):
  exige listener HTTPS + domínio próprio, que dependem do item 3
  (WAF/HTTPS/ACM), ainda pendente por falta de domínio. Quando o item 3 for
  resolvido, dá pra considerar mover a validação do JWT pro próprio ALB.
