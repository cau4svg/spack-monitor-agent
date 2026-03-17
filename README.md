# Spack Monitor Agent

Agente de monitoramento em Bash para Ubuntu 24.04, pensado para ser instalado em cada servidor que executa uma API Node.js via PM2 no padrao `apiwhatsapp-XXXX`.

O projeto detecta automaticamente o processo PM2 do host, deriva os nomes necessários, instala um agente em `/opt/spack-monitor` e roda o monitor continuamente via `systemd`, com checagem padrão a cada 10 segundos.

## Estrutura do repositório

```text
spack-monitor-agent/
├── .env.monitor.example
├── install.sh
├── uninstall.sh
├── src/
│   └── monitor.sh
└── systemd/
    └── spack-monitor.service
```

## O que o agente monitora

- Status do processo PM2 via `pm2 show`
- PID via `pm2 pid`
- CPU via `ps`
- Memória via `ps` usando RSS convertido para MB
- Contador de restarts via `pm2 show`
- Disponibilidade da URL via `curl` com requisição `GET`

## Regras de derivação automática

Ao encontrar um processo PM2 no padrão `apiwhatsapp-XXXX`, o instalador gera:

- `PM2_NAME=apiwhatsapp-XXXX`
- `SERVER_NAME=WHATSAPP-XXXX`
- `HEALTH_URL=https://apiwhatsapp-XXXX.apibrasil.com.br`

Também define `HOST_LABEL` automaticamente com o `hostname -s` do servidor, podendo ser ajustado depois no `.env.monitor`.

## Por que `systemd` em vez de `cron`

`systemd` é a opção preferida aqui porque mantém um processo único e contínuo, com:

- `Restart=always`
- logs centralizados no `journalctl`
- inicialização automática no boot
- menos fragmentação e menos risco operacional do que várias entradas de `cron`

Para este caso, um loop controlado com `sleep 10` é mais simples de manter e mais robusto em produção.

## Pré-requisitos

- Ubuntu 24.04
- `systemd`
- PM2 já instalado e com o processo da API já rodando
- acesso root ou `sudo`
- bot e chat do Telegram já existentes

## Instalação

Clone o repositório e execute:

```bash
sudo bash install.sh
```

O `install.sh` faz o seguinte:

1. Instala dependências base (`curl`, `ca-certificates`, `procps`)
2. Detecta o binário do PM2, inclusive em instalações via NVM
3. Detecta o processo `apiwhatsapp-XXXX`
4. Deriva `SERVER_NAME` e `HEALTH_URL`
5. Cria `/opt/spack-monitor`
6. Copia `monitor.sh`
7. Gera ou atualiza `/opt/spack-monitor/.env.monitor`
8. Instala a unit `systemd`
9. Habilita start automático no boot
10. Reinicia o serviço com a configuração atual

Se for a primeira instalação, ajuste os segredos:

```bash
sudo nano /opt/spack-monitor/.env.monitor
sudo systemctl restart spack-monitor.service
```

Campos obrigatórios:

- `BOT_TOKEN`
- `CHAT_ID`

## Atualização

Atualização padronizada:

```bash
git pull
sudo bash install.sh
```

Esse fluxo é idempotente:

- não quebra uma instalação existente
- preserva `BOT_TOKEN` e `CHAT_ID`
- reaplica o `monitor.sh`
- reaplica a unit do `systemd`
- recalcula automaticamente `PM2_NAME`, `SERVER_NAME` e `HEALTH_URL`

## Remoção

Para remover o agente do servidor:

```bash
sudo bash uninstall.sh
```

O `uninstall.sh`:

- para o serviço
- desabilita a unit
- remove `/etc/systemd/system/spack-monitor.service`
- remove `/opt/spack-monitor`

## Logs e inspeção

Status do serviço:

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

Após a instalação:

```text
/opt/spack-monitor/
├── .env.monitor
├── .env.monitor.example
├── logs/
│   └── monitor.log
├── monitor.sh
└── state/
    ├── pm2_status
    ├── restart_count
    └── url_status
```

## Alertas enviados ao Telegram

O agente envia alertas quando:

- o processo PM2 cai
- o processo PM2 volta
- o contador de restart muda
- a URL fica indisponível
- a URL volta ao normal

Formato do alerta de reinício:

```text
⚠️ PROCESSO REINICIADO
Servidor: WHATSAPP-XXXX
Host: 187
Processo: apiwhatsapp-XXXX
PID: 104002
Status PM2: online
CPU: 99.2%
Memoria: 164.5mb
Restarts: 3 -> 4
```

## Configuração

Use o arquivo abaixo como referência de variáveis:

- [`.env.monitor.example`](/c:/www/spack-monitor-agent/.env.monitor.example)

Na instalação real, o arquivo ativo fica em:

- `/opt/spack-monitor/.env.monitor`

## Comandos operacionais úteis

Reinstalar após ajuste manual do repositório:

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

Ver a configuração ativa:

```bash
sudo cat /opt/spack-monitor/.env.monitor
```
