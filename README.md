# Cobweb

Cobweb e um orquestrador simples para configurar um Nginx acting como reverse proxy (porteiro/seguranca) na porta 443.  
Ele cuida da emissao do certificado TLS usando **acme.sh** com o desafio `TLS-ALPN-01`, evitando abrir a porta 80.  
Toda a automacao roda via `make`, com cada alvo delegando a scripts dedicados armazenados em `scripts/`.

## Requisitos
- Ubuntu (testado no 22.04) rodando na instancia OCI.
- Somente as portas 22 (SSH) e 443 (HTTPS) precisam estar liberadas externamente.
- Dominio/subdominio apontando para o IP publico da instancia.
- Usuario com permissao sudo (os scripts instalam pacotes, mexem em `/etc/nginx` e `/etc/letsencrypt`).
- Durante o `make config`, o Nginx deve estar parado: o acme.sh sobe um servidor ALPN na porta 443.

## Fluxo principal
```bash
# 1. Instala dependencias do sistema e o acme.sh
make install

# 2. Coleta dominio/email, emite o certificado via acme.sh e gera a configuracao do Nginx
make config

# 3. Valida configuracao e sobe/recarrega o Nginx
make run
```

### O que cada etapa faz
- `make install`  
  - Atualiza os indices do apt e instala `nginx`, `curl` e `socat` (requisito do desafio ALPN).  
  - Instala/atualiza o **acme.sh** em `/opt/acme.sh` (email padrao pode ser ajustado com a variavel `ACME_DEFAULT_EMAIL`) e cria o link `/usr/local/bin/acme.sh`.  
  - Remove o site padrao do Nginx, habilita o serviço em systemd e garante que ele esteja parado.

- `make config`  
  - Pergunta dominio, email (usado no registro da conta ACME) e rotas a proxyar.  
  - Registra/atualiza a conta no acme.sh e emite o certificado com `--issue --alpn`, salvando em `/etc/letsencrypt/live/<dominio>/`.  
  - Gera `config/cobweb.conf` a partir do template e sincroniza para `/etc/nginx/sites-available/cobweb.conf`.  
  - Valida a configuracao com `nginx -t`.

- `make run`  
  - Executa `nginx -t` e inicia/recarrega o serviço `nginx`.  
  - Mostra um resumo do status (`systemctl status nginx --lines=3`).

Operacoes complementares:
```bash
make stop     # para o Nginx
make restart  # executa nginx -t e systemctl restart nginx
```

## Ajustando rotas e upstreams
- As escolhas ficam salvas em `config/settings.json`.  
- Rode `make config` novamente para alterar rotas; os valores atuais aparecem como padrao.  
- Para rotas baseadas em caminho (`/api/`, `/grafana/`), mantenha a barra final para evitar duplicacao de path no `proxy_pass`.  
- Se deixar o upstream de `/` vazio, o Cobweb responde `404` na raiz e atende apenas subcaminhos configurados.

## Estrutura gerada
```
.
|-- Makefile
|-- README.md
|-- .gitignore
|-- scripts/
|   |-- install.sh      # instala dependencias e acme.sh
|   |-- config.py       # coleta dados, emite certificado e escreve o nginx.conf
|   |-- run.sh          # valida e inicia/recarrega o nginx
|   |-- stop.sh         # para o nginx
|   `-- restart.sh      # reinicia o nginx
|-- templates/
|   `-- cobweb.conf.tpl # template do servidor HTTPS
`-- config/
    |-- cobweb.conf     # (gerado) configuracao ativa usada pelo nginx
    `-- settings.json   # (gerado) cache das respostas do wizard
```

Arquivos gerados (`config/cobweb.conf` e `config/settings.json`) estao listados no `.gitignore` para evitar versionar dados especificos do ambiente.

## Renovacao automatica
- O acme.sh instala um cron job (rodando como root) que verifica certificados diariamente.  
- Os certificados continuam sendo salvos no home do acme.sh e o script `make config` garante a instalacao em `/etc/letsencrypt/live/<dominio>/`.  
- Para testar manualmente a renovacao/reinstalacao:
  ```bash
  sudo acme.sh --home /opt/acme.sh --renew -d seu.dominio --force --alpn
  sudo acme.sh --home /opt/acme.sh --install-cert \
    -d seu.dominio \
    --key-file /etc/letsencrypt/live/seu.dominio/privkey.pem \
    --fullchain-file /etc/letsencrypt/live/seu.dominio/fullchain.pem \
    --reloadcmd "systemctl reload nginx"
  ```
  (o `--force` deve ser usado com moderacao para nao extrapolar limites da Let's Encrypt).

## Verificando conectividade
Depois do `make run`, valide:
- `sudo nginx -t` continua retornando `syntax is ok`.
- `sudo systemctl status nginx` exibe o servico como `active (running)`.
- `curl -I https://seu.dominio` confirma o handshake TLS e a resposta esperada do upstream.

## Problemas comuns
- **acme.sh reclama da porta 443 em uso:** certifique-se de que `make stop` foi executado ou que nenhum outro processo usa a porta antes da emissao.  
- **Dominio nao resolve para o IP correto:** ajuste o DNS antes de tentar emitir o certificado.  
- **Rotas nao aplicam:** rode `make config` novamente (para regenerar o arquivo) e depois `make run`.  
- **Permissao negada ao gravar em `/etc/letsencrypt`:** garanta que os comandos sejam executados por um usuario com sudo (o script pede sudo automaticamente quando necessario).

## Proximos passos sugeridos
- Customizar o template `templates/cobweb.conf.tpl` com headers adicionais, limitacoes de taxa, rate limiting etc.  
- Adicionar monitoramento (ex: checar `/healthz`).  
- Manter um documento com as rotas/upstreams provisionados para facilitar auditoria ou reproducao em outro ambiente.
