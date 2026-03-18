# Spack Monitor Agent

Agente de monitoramento em Bash para Ubuntu 24.04, pensado para ser instalado em cada servidor que executa uma API Node.js via PM2 no padrao `apiwhatsapp-XXXX`.

O projeto detecta automaticamente o processo PM2 do host, deriva os nomes necessarios, instala um agente em `/opt/spack-monitor` e roda o monitor continuamente via `systemd`, com checagem padrao a cada 10 segundos.

## Estrutura do repositorio

```text
spack-monitor-agent/
|-- .env.monitor.example
|-- bootstrap-install.sh
|-- install.sh
|-- uninstall.sh
|-- src/
|   `-- monitor.sh
`-- systemd/
    `-- spack-monitor.service
```

## O que o agente monitora

- Status do processo PM2 via `pm2 show`
- PID via `pm2 pid`
- CPU via `ps`
- Memoria via `ps` usando RSS convertido para MB
- Contador de restarts via `pm2 show`
- Disponibilidade da URL via `curl` com requisicao `GET`

## Regras de derivacao automatica

Ao encontrar um processo PM2 no padrao `apiwhatsapp-XXXX`, o instalador gera:

- `PM2_NAME=apiwhatsapp-XXXX`
- `SERVER_NAME=WHATSAPP-XXXX`
- `HEALTH_URL=https://apiwhatsapp-XXXX.apibrasil.com.br`

Tambem define `HOST_LABEL` automaticamente com o `hostname -s` do servidor, podendo ser ajustado depois no `.env.monitor`.

## Por que `systemd` em vez de `cron`

`systemd` e a opcao preferida aqui porque mantem um processo unico e continuo, com:

- `Restart=always`
- logs centralizados no `journalctl`
- inicializacao automatica no boot
- menos fragmentacao e menos risco operacional do que varias entradas de `cron`

Para este caso, um loop controlado com `sleep 10` e mais simples de manter e mais robusto em producao.

## Pre-requisitos

- Ubuntu 24.04
- `systemd`
- PM2 ja instalado e com o processo da API ja rodando
- acesso root ou `sudo`
- bot e chat do Telegram ja existentes

## Instalacao

Clone o repositorio e execute:

```bash
sudo bash install.sh
```

Se quiser fazer tudo direto no servidor, sem clone manual, use o bootstrap:

```bash
curl -fsSL https://raw.githubusercontent.com/cau4svg/spack-monitor-agent/main/bootstrap-install.sh | sudo bash
```

Esse fluxo baixa ou atualiza o repositorio em `/usr/local/src/spack-monitor-agent` e depois chama o `install.sh`.

Parametros opcionais do bootstrap:

- `--repo`: troca a URL do repositorio
- `--branch`: escolhe a branch
- `--dir`: muda o diretorio local do checkout

Exemplo com branch explicita:

```bash
curl -fsSL https://raw.githubusercontent.com/cau4svg/spack-monitor-agent/main/bootstrap-install.sh | sudo bash -s -- --branch main
```

Se a instalacao for disparada da sua maquina para um servidor remoto:

```bash
ssh usuario@SEU_SERVIDOR 'curl -fsSL https://raw.githubusercontent.com/cau4svg/spack-monitor-agent/main/bootstrap-install.sh | sudo bash'
```

O `install.sh` faz o seguinte:

1. Instala dependencias base (`curl`, `ca-certificates`, `procps`)
2. Detecta o binario do PM2, inclusive em instalacoes via NVM
3. Detecta o processo `apiwhatsapp-XXXX`
4. Deriva `SERVER_NAME` e `HEALTH_URL`
5. Cria `/opt/spack-monitor`
6. Copia `monitor.sh`
7. Gera ou atualiza `/opt/spack-monitor/.env.monitor`
8. Instala a unit `systemd`
9. Habilita start automatico no boot
10. Reinicia o servico com a configuracao atual

Se for a primeira instalacao, ajuste os segredos:

```bash
sudo nano /opt/spack-monitor/.env.monitor
sudo systemctl restart spack-monitor.service
```

Campos obrigatorios:

- `BOT_TOKEN`
- `CHAT_ID`

## Atualizacao

Atualizacao padronizada:

```bash
git pull
sudo bash install.sh
```

Se preferir atualizar sem entrar no diretorio do projeto:

```bash
sudo bash /usr/local/src/spack-monitor-agent/bootstrap-install.sh
```

Ou disparando da sua maquina:

```bash
ssh usuario@SEU_SERVIDOR 'sudo bash /usr/local/src/spack-monitor-agent/bootstrap-install.sh'
```

Esse fluxo e idempotente:

- nao quebra uma instalacao existente
- preserva `BOT_TOKEN` e `CHAT_ID`
- reaplica o `monitor.sh`
- reaplica a unit do `systemd`
- recalcula automaticamente `PM2_NAME`, `SERVER_NAME` e `HEALTH_URL`

## Remocao

Para remover o agente do servidor:

```bash
sudo bash uninstall.sh
```

O `uninstall.sh`:

- para o servico
- desabilita a unit
- remove `/etc/systemd/system/spack-monitor.service`
- remove `/opt/spack-monitor`

## Logs e inspecao

Status do servico:

```bash
sudo systemctl status spack-monitor.service
```

Logs via `journalctl`:

```bash
sudo journalctl -u spack-monitor.service -f
```

Log simples em arquivo:

```bash
sudo tail -f /opt/spack-monitor/logs/monitor.log
```

## Arquivos gerados no servidor

Apos a instalacao:

```text
/opt/spack-monitor/
|-- .env.monitor
|-- .env.monitor.example
|-- logs/
|   `-- monitor.log
|-- monitor.sh
`-- state/
    |-- pm2_status
    |-- restart_count
    `-- url_status
```

## Alertas enviados ao Telegram

O agente envia alertas quando:

- o processo PM2 cai
- o processo PM2 volta
- o contador de restart muda
- a URL fica indisponivel
- a URL volta ao normal

Formato do alerta de reinicio:

```text
PROCESSO REINICIADO
Servidor: WHATSAPP-XXXX
Host: 187
Processo: apiwhatsapp-XXXX
PID: 104002
Status PM2: online
CPU: 99.2%
Memoria: 164.5mb
Restarts: 3 -> 4
```

## Configuracao

Use o arquivo abaixo como referencia de variaveis:

- [`.env.monitor.example`](/c:/www/spack-monitor-agent/.env.monitor.example)

Na instalacao real, o arquivo ativo fica em:

- `/opt/spack-monitor/.env.monitor`

## Comandos operacionais uteis

Reinstalar apos ajuste manual do repositorio:

```bash
sudo bash install.sh
```

Reiniciar o agente:

```bash
sudo systemctl restart spack-monitor.service
```

Parar o agente:

```bash
sudo systemctl stop spack-monitor.service
```

Ver a configuracao ativa:

```bash
sudo cat /opt/spack-monitor/.env.monitor
```
