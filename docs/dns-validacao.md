# Validação DNS do ACM (domínio fora do Route53)

Referente ao item 3 de `melhorias.md`. O domínio usado (`eriknathan.me`,
subdomínio sugerido `flowqueue.eriknathan.me`) está registrado na
**Hostinger**, não no Route53 — por isso `terraform/modules/certificates`
**não** cria o `aws_route53_record` de validação automaticamente. Esse
passo precisa ser feito manualmente, uma vez, fora do Terraform.

## Passo a passo

1. Configure `domain_name = "flowqueue.eriknathan.me"` (ou o subdomínio que
   preferir) em `environments/aws/terraform.tfvars` — ver
   `environments/aws/terraform.tfvars.example`.
2. Rode `terraform apply` (ou `terraform apply -target=module.certificates`
   pra isolar só essa parte). O `aws_acm_certificate` é criado na hora, mas
   o `aws_acm_certificate_validation` fica **parado esperando** a AWS
   confirmar o certificado como `ISSUED` — é esperado, não é erro.
3. Em outro terminal, veja os registros a criar:
   ```bash
   terraform -chdir=terraform output -json acm_dns_validation_records
   ```
   Isso mostra até dois grupos (`regional` e `cloudfront`) — na prática,
   pra um mesmo domínio, os dois costumam pedir o **mesmo** registro CNAME
   (a validação é por posse do domínio, não por certificado). Confira os
   dois antes de assumir que são idênticos.
4. No painel da Hostinger (Domínios → DNS / Zona DNS), crie um registro
   **CNAME** com o `name` e `value` exatos que apareceram no output. Não
   inclua o sufixo do domínio duas vezes — a Hostinger costuma pedir só a
   parte antes do domínio raiz no campo "Nome".
5. Aguarde a propagação (minutos, às vezes até 1h) e volte pro terminal
   onde o `apply` ficou esperando — ele deve concluir sozinho assim que a
   AWS enxergar o registro. Se preferir, cancele (`Ctrl+C`) e rode o
   `apply` de novo mais tarde; o certificado já criado (`PENDING_VALIDATION`)
   continua lá, o Terraform só volta a esperar a validação.

## Por que não dá pra automatizar isso

`aws_route53_record` só funciona se a zona DNS do domínio estiver hospedada
no Route53 (delegação de nameservers pra AWS). Migrar o domínio da
Hostinger pro Route53 resolveria isso, mas é uma mudança bem maior
(nameservers, e-mail, outros registros que já existam) — fora do escopo
desta melhoria. Se um dia isso for feito, dá pra trocar o passo manual
acima por `aws_route53_record` + `validation_record_fqdns` no
`aws_acm_certificate_validation`, sem mudar mais nada na arquitetura.

## Sobre testar isso contra o Floci

Esse fluxo depende de validação DNS real contra a AWS — não dá pra
exercitar fim a fim contra o Floci (que também trava no CloudFront, ver
`terraform/README.md`). O que foi validado localmente foi só
`terraform validate`/`plan` (grafo de dependências e sintaxe corretos).
