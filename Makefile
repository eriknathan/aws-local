.PHONY: up down restart logs ps sh reset tf-init tf-plan tf-apply tf-destroy

up:
	docker compose up -d --build --force-recreate

down:
	docker compose down

restart: down up

logs:
	docker compose logs -f floci

ps:
	docker compose ps

sh:
	docker compose exec floci sh

reset:
	docker compose down -v
	rm -rf data/*

TF_VARS := -var-file=environments/local/terraform.tfvars

tf-init:
	terraform -chdir=terraform init

tf-plan:
	terraform -chdir=terraform plan $(TF_VARS)

tf-apply:
	terraform -chdir=terraform apply $(TF_VARS)

tf-destroy:
	terraform -chdir=terraform destroy $(TF_VARS)
