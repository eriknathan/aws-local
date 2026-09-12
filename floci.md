# Floci — Emulador Local de AWS

> **Any Cloud. Locally.** — Leve, gratuito e sempre disponível.

Documentação de referência sobre o projeto **Floci**, um emulador AWS local, gratuito e open-source, criado como alternativa direta ao LocalStack.

- Site oficial: https://floci.io/aws/
- Repositório: https://github.com/floci-io/floci
- Docs oficiais: https://floci.io/floci/
- Licença: MIT

---

## 1. O que é o Floci

Floci é um **emulador local de serviços AWS** voltado para desenvolvimento, testes e CI/CD. Ele simula cerca de 100 serviços da AWS rodando inteiramente na máquina do desenvolvedor (ou em um runner de CI), sem exigir conta na AWS, cartão de crédito, token de autenticação ou qualquer tipo de "feature gate" pago.

A ideia central é simples: você aponta seu SDK da AWS, AWS CLI, Terraform, CDK, OpenTofu ou suíte de testes para `http://localhost:4566` e continua usando exatamente os mesmos comandos e código que usaria contra a AWS real.

Floci faz parte de uma família de emuladores da mesma equipe, cada um cobrindo um provedor de nuvem diferente:

| Emulador | Nuvem | Porta padrão |
|---|---|---|
| **floci** | AWS | 4566 |
| floci-az | Azure | 4577 |
| floci-gcp | GCP | 4588 |
| floci-oci | Oracle Cloud (OCI) | 4599 |

O nome vem de *floccus* (cirrocumulus floccus), a formação de nuvem que parece pipoca — uma referência ao conceito de algo leve, fofo e sempre presente.

### 1.1 Por que o projeto existe

Em março de 2026, a edição Community do LocalStack — usada gratuitamente por milhares de pipelines de CI e ambientes de desenvolvimento — passou a exigir token de autenticação e teve suas atualizações de segurança congeladas. Isso deixou uma lacuna real para quem dependia da ferramenta sem custo. O Floci nasceu como resposta a essa lacuna: um substituto **drop-in** (compatível na porta, protocolo e chamadas de SDK), mas licenciado em MIT puro, sem edição "community" que expira e sem funcionalidades trancadas atrás de plano pago.

---

## 2. Como funciona

### 2.1 Tecnologia por trás

Floci é escrito em Java, construído sobre **Quarkus** e compilado para um **binário nativo** via **GraalVM Mandrel**. Essa escolha técnica é responsável pelos números de desempenho divulgados pelo projeto:

| Métrica | Floci (nativo) | Emulador típico (ex: LocalStack Community) |
|---|---|---|
| Tempo de startup | ~24 ms | ~3,3 s (~6 s em outras medições) |
| Memória em idle | ~13 MiB | ~143–250 MiB |
| Tamanho da imagem Docker | ~90 MB | ~1,0 GB |
| Tamanho do binário nativo | ~40 MB | — |
| Licença | MIT | Restrita (community exige token) |

> ⚠️ **Nota de precisão**: fontes de terceiros (blogs e sites de análise) publicaram números divergentes sobre quantidade de serviços suportados (47, 85 ou 100, dependendo da data da matéria) e sobre uso de memória. Isso provavelmente reflete a evolução rápida do projeto ao longo de 2026. A tabela de serviços na seção 3 segue o README oficial do repositório, que é a fonte mais confiável.

### 2.2 Arquitetura geral

Floci expõe um único endpoint HTTP (porta 4566 por padrão) que fala o protocolo de fio (wire protocol) real da AWS — REST, JSON 1.0/1.1, Query, etc., dependendo do serviço. Internamente, as requisições passam por um roteador HTTP (JAX-RS / Vert.x) e são despachadas para três grandes grupos de implementação:

1. **Serviços sem estado** (stateless) — ex: IAM, STS, KMS, SQS, SNS, Secrets Manager, SES, Cognito, EventBridge, CloudWatch, Step Functions, CloudFormation, API Gateway, ACM, Config, CloudTrail, ELB v2, Auto Scaling, Elastic Beanstalk, CodeDeploy, CodePipeline, AWS Backup, FIS, Bedrock, Route53, Transfer Family, entre outros — respondidos inteiramente em memória/processo.
2. **Serviços com estado** (stateful) — ex: S3 e DynamoDB (+ Streams) — que persistem dados através de um backend de armazenamento configurável.
3. **Serviços orquestrados via Docker real** — para os casos em que uma simulação "rasa" comprometeria a fidelidade, o Floci sobe **containers Docker reais** (Lambda, ElastiCache, RDS, Neptune, ECS, EC2, MSK, EKS, OpenSearch, CodeBuild, Managed Service for Apache Flink, entre outros), falando com o Docker Engine via API, incluindo autenticação IAM/SigV4 quando aplicável.

Um caso especial é o **Athena**, que roda consultas SQL reais contra um sidecar **DuckDB** (chamado internamente de `floci-duck`), em vez de apenas simular respostas.

Todos os serviços stateless e stateful gravam num **StorageBackend** comum, cujo modo de operação é configurável (ver seção 5).

### 2.3 "Real Docker onde a fidelidade importa"

Esse é o principal diferencial técnico do projeto frente a emuladores que apenas devolvem respostas mockadas. Para serviços onde o comportamento real do motor por trás importa — bancos de dados, protocolos com estado de conexão, runtimes de execução e sistemas de build — o Floci sobe o motor de verdade em um container:

| Serviço | Imagem padrão | O que é real |
|---|---|---|
| Lambda | `public.ecr.aws/lambda/<runtime>` | Ambiente de execução e runtime oficial da AWS, pool de containers "quentes" |
| ElastiCache | `valkey/valkey:8` | Protocolo Redis/Valkey, autenticação IAM via ACL, validação SigV4 |
| RDS (PostgreSQL) | `postgres:16-alpine` | Motor PostgreSQL real, autenticação IAM, acesso via JDBC |
| RDS (MySQL/Aurora) | `mysql:8.0` | Motor MySQL real, autenticação IAM |
| RDS (MariaDB) | `mariadb:11` | Motor MariaDB real |
| Neptune | `tinkerpop/gremlin-server:3.7.3` (ou `neo4j:5-community` para openCypher) | Banco de grafos real via Gremlin WebSocket (porta 8182) |
| DocumentDB | `mongo:7.0` | Motor MongoDB real, protocolo wire na porta 27017 |
| MSK | `redpandadata/redpanda:latest` | Broker Kafka-compatível via Redpanda |
| Amazon MQ | `rabbitmq:3-management` | Broker RabbitMQ real (AMQP + console de gestão) |
| Managed Flink | `apache/flink:<versão>` | Cluster Flink real (JobManager + TaskManager) |
| EC2 | Imagens Linux mapeadas por AMI | Containers Linux reais, injeção de chave SSH, UserData, IMDS |
| ECS | Imagem informada na task definition | Ciclo de vida real de containers |
| EKS | `rancher/k3s:latest` | Cluster Kubernetes real via k3s |
| MWAA | `apache/airflow:<versão>` + `postgres:16-alpine` | Apache Airflow real (LocalExecutor) com seu próprio banco de metadados |
| CodeBuild | Imagem de ambiente informada pelo usuário | Execução real de buildspec |
| OpenSearch | `opensearchproject/opensearch:2` | Motor OpenSearch completo |
| ECR | `registry:2` | Registro OCI-compatível real (docker push/pull) |

Todas essas imagens podem ser sobrescritas via variáveis de ambiente (ex: `FLOCI_SERVICES_ELASTICACHE_DEFAULT_IMAGE`, `FLOCI_SERVICES_RDS_DEFAULT_POSTGRES_IMAGE`, `FLOCI_SERVICES_NEPTUNE_DEFAULT_IMAGE`, etc.).

Para usar os serviços apoiados em Docker, o container do Floci precisa de acesso ao socket do Docker do host:

```bash
docker run -d --name floci \
  -p 4566:4566 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -u root \
  floci/floci:latest
```

---

## 3. Serviços suportados

Floci cobre categorias amplas do catálogo AWS. Um resumo por categoria:

| Categoria | Exemplos de serviços |
|---|---|
| Serviços de aplicação centrais | S3, SQS, SNS, DynamoDB, Lambda, IAM, KMS, Secrets Manager, SSM |
| Eventos e workflows | EventBridge (+ Pipes e Scheduler), Step Functions, SWF, CloudWatch Logs/Metrics/RUM, Managed Prometheus |
| API e identidade | API Gateway REST e v2, AppSync, Cognito, ACM, Route53 (+ Resolver), Cloud Map |
| Containers e computação | ECS, EC2, Lightsail, EKS, MWAA, ECR, EFS, CodeBuild, CodeDeploy, CodePipeline, CodeGuru Reviewer, Batch, Auto Scaling, Elastic Beanstalk, ELB v2/Classic |
| Dados, analytics e IA | Athena, Glue, Lake Formation, EMR (+ Serverless), Redshift, Firehose, Managed Flink, OpenSearch, S3 Tables/Vectors, Textract, Transcribe, Comprehend, Rekognition, Translate, Bedrock Runtime/AgentCore |
| Bancos de dados e cache | RDS, RDS Data API, Neptune, DocumentDB, MemoryDB, ElastiCache |
| Mensageria e transferência | SES, Kinesis, MSK, Amazon MQ, Transfer Family, IoT Core, Amazon Connect |
| Segurança e governança | Network Firewall, RAM, Service Quotas, WAF v2, GuardDuty, Inspector, CloudTrail, CloudFront, Resource Groups Tagging, Resource Explorer 2, CloudHSM, Organizations, IAM Identity Center, Macie, Detective, Security Hub, Control Tower, Service Catalog |
| Custo e faturamento | Budgets, Pricing, Cost Explorer, Cost and Usage Reports, BCM Data Exports |
| Resiliência, backup e config | FIS, Backup, Config, AppConfig, CloudFormation, Cloud Control API |

### 3.1 Nível de implementação de cada serviço

Cada serviço é implementado com uma abordagem diferente: puramente em processo (in-process), em processo com um sidecar auxiliar (ex: Athena → DuckDB), ou via Docker real. Alguns pontos relevantes:

- **S3**: versionamento, multipart upload, URLs pré-assinadas, Object Lock, notificações de eventos.
- **DynamoDB**: GSI/LSI, Query/Scan, TTL, transações, Streams com shard iterators e integração com Lambda.
- **Lambda**: ambiente de execução real via Docker, pool de containers quentes, aliases, Function URLs, triggers de SQS/Kinesis/DynamoDB Streams.
- **IAM/STS**: usuários, papéis, grupos, políticas; AssumeRole, WebIdentity, SAML, GetFederationToken.
- **CloudFormation**: stacks, change sets, StackSets entre contas.
- **Step Functions**: execução real de ASL, tokens de tarefa, histórico de execução.
- **Bedrock Runtime / AgentCore / Textract / Transcribe**: implementados como *stubs* — respondem no formato correto da API, mas sem processamento real de IA por trás (ex: transcrição termina instantaneamente, sem processar áudio de verdade).

Para o detalhamento operação a operação, o projeto mantém uma página dedicada em https://floci.io/floci/services/.

---

## 4. Isolamento multi-conta

Floci suporta isolamento de recursos por conta sem configuração extra:

- Se `AWS_ACCESS_KEY_ID` tiver exatamente 12 dígitos, esse valor é usado como o ID da conta. Recursos criados por uma conta ficam invisíveis para outra.
- Qualquer outro formato de chave (`test`, `AKIA...` etc.) faz o Floci cair no valor de `FLOCI_DEFAULT_ACCOUNT_ID` (padrão: `000000000000`).
- Credenciais temporárias obtidas via `AssumeRole` (STS) também são resolvidas corretamente para a conta do papel assumido, permitindo testar fluxos de assume-role entre contas localmente.

```bash
AWS_ACCESS_KEY_ID=111111111111 aws sqs create-queue --queue-name orders
AWS_ACCESS_KEY_ID=222222222222 aws sqs create-queue --queue-name orders
# As duas filas "orders" são independentes uma da outra
```

---

## 5. Persistência e modos de armazenamento

O modo de armazenamento é configurável via `FLOCI_STORAGE_MODE` (globalmente) ou por serviço:

| Modo | Comportamento | Melhor para | Durabilidade |
|---|---|---|---|
| `memory` | Tudo em RAM; dados somem ao parar o container | CI e testes efêmeros | Nenhuma |
| `persistent` | Carrega do disco na inicialização, grava imediatamente a cada escrita | Preservação simples de estado local | Média |
| `hybrid` | Desempenho de memória, com flush assíncrono a cada ~5s | Desenvolvimento local do dia a dia | Boa |
| `wal` | Write-ahead log — cada mutação é registrada antes de responder | Máxima durabilidade | Mais alta |

Para começar rápido, `memory` (padrão) é suficiente. Para manter estado entre reinícios sem grande overhead, `hybrid` costuma ser o equilíbrio recomendado.

---

## 6. Instalação e Quick Start

### 6.1 Via CLI oficial (recomendado)

Instalação por gerenciador de pacotes:

```bash
# Homebrew (macOS/Linux)
brew install floci-io/floci/floci

# curl (Linux/macOS)
curl -fsSL https://floci.io/install.sh | sh

# PowerShell (Windows)
iwr https://floci.io/install.ps1 | iex

# Scoop (Windows)
scoop bucket add floci https://github.com/floci-io/scoop-floci
scoop install floci
```

Fluxo básico:

```bash
# 1. Subir o emulador
floci start

# 2. Exportar as variáveis de ambiente da AWS
eval $(floci env)
# exporta AWS_ENDPOINT_URL, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION

# 3. Usar normalmente com a AWS CLI
aws s3 mb s3://my-bucket
echo "teste" > hello.txt
aws s3 cp hello.txt s3://my-bucket/hello.txt
aws s3 cp s3://my-bucket/hello.txt hello-back.txt
cat hello-back.txt
```

Outros comandos úteis do CLI:

```bash
floci status          # ver status
floci logs --follow   # acompanhar logs em tempo real
floci stop            # parar o emulador
floci doctor          # diagnóstico de saúde do ambiente

floci start --persist ./data      # iniciar com persistência em disco
floci snapshot save my-snapshot   # salvar um snapshot do estado
floci snapshot restore my-snapshot
```

### 6.2 Via Docker direto

```bash
docker run -d --name floci \
  -p 4566:4566 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  floci/floci:latest
```

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
```

### 6.3 Via Docker Compose

```yaml
services:
  floci:
    image: floci/floci:latest
    ports:
      - "4566:4566"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/app/data
    environment:
      FLOCI_STORAGE_MODE: hybrid
```

```bash
docker compose up
```

### 6.4 Compose multi-container (app + Floci em containers separados)

Quando a sua aplicação roda em outro container (não no host), é preciso definir `FLOCI_HOSTNAME` para que URLs devolvidas (por exemplo, `QueueUrl` do SQS) resolvam corretamente para o nome do serviço, e não para `localhost`:

```yaml
services:
  floci:
    image: floci/floci:latest
    ports:
      - "4566:4566"
    environment:
      - FLOCI_HOSTNAME=floci

  my-app:
    environment:
      - AWS_ENDPOINT_URL=http://floci:4566
    depends_on:
      - floci
```

### 6.5 Tags de imagem disponíveis

| Canal | Padrão | Com AWS CLI e boto3 embutidos |
|---|---|---|
| Release, flutuante | `latest` | `latest-compat` |
| Release, fixado | `x.y.z` | `x.y.z-compat` |
| Nightly, flutuante | `nightly` | `nightly-compat` |
| Nightly, datado | `nightly-mmddyyyy` | `nightly-mmddyyyy-compat` |

Use `latest` para uso geral, uma versão fixada (`x.y.z`) para builds reprodutíveis, e `nightly` para acompanhar a branch `main`. O calendário de releases estáveis é a **1ª e 3ª terça-feira de cada mês**; entre um release e outro, a tag `nightly` acompanha as últimas correções mescladas.

---

## 7. Configuração

Todas as opções são configuráveis via variáveis de ambiente com prefixo `FLOCI_`. As mais comuns:

| Variável | Padrão | Descrição |
|---|---|---|
| `FLOCI_PORT` | `4566` | Porta exposta pela API do Floci |
| `FLOCI_DEFAULT_REGION` | `us-east-1` | Região AWS padrão |
| `FLOCI_DEFAULT_ACCOUNT_ID` | `000000000000` | ID de conta AWS padrão |
| `FLOCI_BASE_URL` | `http://localhost:4566` | URL base usada nas respostas do Floci |
| `FLOCI_HOSTNAME` | (vazio) | Hostname usado nas URLs retornadas quando roda em Docker Compose |
| `FLOCI_STORAGE_MODE` | `memory` | Modo de armazenamento: `memory`, `persistent`, `hybrid` ou `wal` |
| `FLOCI_STORAGE_PERSISTENT_PATH` | `./data` | Diretório usado para persistir estado |
| `FLOCI_SERVICES_LAMBDA_ECR_BASE_URI` | `public.ecr.aws` | URI base do ECR usada para baixar as imagens de runtime do Lambda |
| `FLOCI_SERVICES_S3_ENFORCE_AUTH` | `false` | Ativa a validação real de acesso público/privado do S3 |

A referência completa de configuração está em https://floci.io/floci/configuration/advanced/application-yml.

---

## 8. Integração com SDKs

Basta apontar o SDK ou CLI para `http://localhost:4566`, usando qualquer credencial não vazia (a menos que verificações de autenticação mais estritas estejam habilitadas para o serviço).

**AWS CLI (Bash)**
```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1

aws --endpoint-url http://localhost:4566 s3 mb s3://my-bucket
aws --endpoint-url http://localhost:4566 s3 ls
```

**Python (boto3)**
```python
import boto3

client = boto3.client(
    "ssm",
    endpoint_url="http://localhost:4566",
    region_name="us-east-1",
    aws_access_key_id="test",
    aws_secret_access_key="test",
)

client.put_parameter(Name="/demo/app/message", Value="hello from floci", Type="String", Overwrite=True)
print(client.get_parameter(Name="/demo/app/message")["Parameter"]["Value"])
```

**Node.js (AWS SDK v3)**
```javascript
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";

const client = new SQSClient({
  endpoint: "http://localhost:4566",
  region: "us-east-1",
  credentials: { accessKeyId: "test", secretAccessKey: "test" },
});

await client.send(new SendMessageCommand({
  QueueUrl: "http://localhost:4566/000000000000/demo-queue",
  MessageBody: "hello from floci",
}));
```

**Java (AWS SDK v2)**
```java
var client = DynamoDbClient.builder()
    .endpointOverride(URI.create("http://localhost:4566"))
    .region(Region.US_EAST_1)
    .credentialsProvider(StaticCredentialsProvider.create(
        AwsBasicCredentials.create("test", "test")))
    .build();

client.createTable(b -> b.tableName("demo-table").billingMode(BillingMode.PAY_PER_REQUEST));
```

**Go (AWS SDK v2)**
```go
cfg, _ := config.LoadDefaultConfig(context.TODO(),
    config.WithRegion("us-east-1"),
    config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider("test", "test", "")),
    config.WithBaseEndpoint("http://localhost:4566"),
)
client := s3.NewFromConfig(cfg, func(o *s3.Options) { o.UsePathStyle = true })
```

Também há suporte para Rust e Terraform (com o provider padrão da HashiCorp), CDK e OpenTofu.

---

## 9. Como testar

Existem três formas principais de testar aplicações contra o Floci:

### 9.1 Testcontainers (recomendado para testes automatizados)

Módulos oficiais permitem subir instâncias isoladas do Floci diretamente dentro dos testes, evitando estado compartilhado e conflitos de porta:

| Linguagem | Pacote | Versão mais recente |
|---|---|---|
| Java | `io.floci:testcontainers-floci` | `1.14.0` (ou `2.15.0` para Testcontainers 2.x / Spring Boot 4.x) |
| Node.js | `@floci/testcontainers` | `0.1.0` |
| Python | `testcontainers-floci` | `0.1.1` |
| Go | em desenvolvimento | — |

**Java**
```java
@Testcontainers
class S3IntegrationTest {

    @Container
    static FlociContainer floci = new FlociContainer();

    @Test
    void shouldCreateBucket() {
        S3Client s3 = S3Client.builder()
                .endpointOverride(URI.create(floci.getEndpoint()))
                .region(Region.of(floci.getRegion()))
                .credentialsProvider(StaticCredentialsProvider.create(
                        AwsBasicCredentials.create(floci.getAccessKey(), floci.getSecretKey())))
                .forcePathStyle(true)
                .build();

        s3.createBucket(b -> b.bucket("my-bucket"));
    }
}
```

**Node.js/TypeScript**
```javascript
import { FlociContainer } from "@floci/testcontainers";

let floci;
beforeAll(async () => { floci = await new FlociContainer().start(); });
afterAll(async () => { await floci.stop(); });
```

**Python**
```python
from floci import FlociContainer
import boto3

def test_s3_create_bucket():
    with FlociContainer() as floci:
        s3 = boto3.client("s3", endpoint_url=floci.get_endpoint(), ...)
        s3.create_bucket(Bucket="my-bucket")
```

### 9.2 Suíte de compatibilidade do próprio projeto

O repositório mantém uma pasta `compatibility-tests` que valida o Floci contra SDKs e ferramentas de infraestrutura reais:

| Módulo | Linguagem/Ferramenta | SDK/Cliente | Nº de testes |
|---|---|---|---|
| `sdk-test-java` | Java 17 | AWS SDK for Java v2 | 1.326 |
| `sdk-test-node` | Node.js | AWS SDK for JavaScript v3 | 449 |
| `sdk-test-python` | Python 3 | boto3 | 311 |
| `sdk-test-go` | Go | AWS SDK for Go v2 + RDS Data API SDK v1 | 157 |
| `sdk-test-awscli` | Bash | AWS CLI v2 | 205 |
| `compat-terraform` | Terraform | v1.10+ | 67 |
| `compat-opentofu` | OpenTofu | v1.9+ | 41 |
| `compat-cdk` | AWS CDK | v2+ | 20 |

No total, são **2.576 testes automatizados** cobrindo 5 SDKs e 3 ferramentas de infraestrutura como código.

### 9.3 Uso manual/exploratório

Para testes rápidos, basta subir o Floci (CLI ou Docker) e usar a AWS CLI apontando para `http://localhost:4566`, como mostrado na seção 6. O CLI oficial também traz `floci doctor` para diagnosticar problemas do ambiente local.

---

## 10. Migrando do LocalStack

Floci foi desenhado para ser um substituto **drop-in**: mesma porta, mesmo padrão de credenciais, mesma configuração de SDK e endpoint de CLI.

```yaml
# Antes
image: localstack/localstack

# Depois — imagem padrão
image: floci/floci:latest

# Depois — se scripts de inicialização precisarem de AWS CLI ou boto3
image: floci/floci:latest-compat
```

Variáveis de ambiente do LocalStack são traduzidas automaticamente:

| LocalStack | Equivalente no Floci |
|---|---|
| `LOCALSTACK_HOST` | `FLOCI_HOSTNAME` |
| `PERSISTENCE=1` | `FLOCI_STORAGE_MODE=persistent` |
| `LAMBDA_DOCKER_NETWORK` | `FLOCI_SERVICES_LAMBDA_DOCKER_NETWORK` |
| `LAMBDA_REMOVE_CONTAINERS=1` | `FLOCI_SERVICES_LAMBDA_EPHEMERAL=true` |
| `DEBUG=1` | `QUARKUS_LOG_LEVEL=DEBUG` |

Scripts de inicialização montados em `/etc/localstack/init/` continuam funcionando sem alteração, e os endpoints `/_localstack/init` e `/_localstack/health` seguem disponíveis. O log de inicialização também termina com a mesma linha `Ready.` do LocalStack, então ferramentas que esperam por ela (como a estratégia de espera padrão do `LocalStackContainer` do Testcontainers) continuam funcionando sem ajustes. Para desativar essa tradução automática, defina `LOCALSTACK_PARITY=false`.

Guia completo: https://floci.io/floci/getting-started/migrate-from-localstack/

---

## 11. Comparativo rápido: Floci vs. LocalStack Community

| Capacidade | Floci | LocalStack Community |
|---|---|---|
| Exige token de autenticação | Não | Sim |
| Atualizações de segurança | Sim | Congeladas |
| Tempo de startup | ~24 ms | ~3,3 s |
| Memória em idle | ~13 MiB | ~143 MiB |
| Tamanho da imagem Docker | ~90 MB | ~1,0 GB |
| Licença | MIT | Restrita |
| API Gateway v2 / HTTP API | Sim | Não |
| Cognito | Sim | Não |
| RDS, ElastiCache, MSK | Docker real | Não |
| Neptune (grafo + Gremlin WebSocket) | Docker real | Não |
| DocumentDB (compatível com MongoDB) | Docker real | Não |
| ECS, EC2, EKS | Docker real | Não |
| CodeBuild | Execução real via Docker | Não |
| Binário nativo | ~40 MB | Não |

> Vale lembrar que existem análises independentes (ex: Wavect, DEV Community) que recomendam validar esses números com a versão específica que você for usar, já que o projeto evolui rápido e alguns comparativos publicados na web já ficaram desatualizados quanto à contagem exata de serviços.

---

## 12. Comunidade, licença e sustentação

- **Licença**: MIT — pode ser usado, modificado e redistribuído livremente.
- **Comunidade**: canal no Slack e GitHub Discussions para dúvidas de compatibilidade, propostas de design e ideias de funcionalidades.
- **Patrocínio**: o projeto é open source independente, mantido por doações/patrocínio da comunidade. Segundo os mantenedores, patrocínio não compra prioridade de roadmap nem funcionalidades exclusivas — tudo continua gratuito para todos.
- **Ciclo de release**: versões estáveis seguem *Conventional Commits* com `semantic-release`; o changelog é gerado automaticamente. Não há branches de manutenção — releases saem sempre a partir da `main`.

---

## 13. Resumo executivo

| Pergunta | Resposta curta |
|---|---|
| O que é? | Emulador local de ~100 serviços AWS, gratuito e open-source |
| Para quê serve? | Desenvolvimento local e CI sem precisar de conta AWS real |
| Como diferencia do LocalStack? | Mais rápido, mais leve, sem token de auth, com mais serviços via Docker real, MIT puro |
| Como instalo? | `floci start` via CLI, ou `docker run` / `docker compose up` |
| Como configuro? | Variáveis de ambiente com prefixo `FLOCI_` |
| Como testo minha aplicação com ele? | Testcontainers (Java/Node/Python), ou apontando SDK/CLI para `localhost:4566` |
| Migro do LocalStack fácil? | Sim — troca de imagem Docker, com tradução automática de variáveis |

---

*Documento gerado a partir do site oficial (floci.io/aws) e do README do repositório GitHub (floci-io/floci), em setembro de 2026.*