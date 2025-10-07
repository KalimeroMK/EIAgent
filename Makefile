COMPOSE ?= docker compose

.PHONY: up down rebuild logs

up:
$(COMPOSE) up -d

down:
$(COMPOSE) down

rebuild:
$(COMPOSE) up -d --build

logs:
$(COMPOSE) logs -f
