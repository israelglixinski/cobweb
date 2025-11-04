# Cobweb

Cobweb e um orquestrador simples para configurar um Nginx em modo reverse proxy (porteiro/seguranca) que expoe suas APIs pela porta 443 com TLS emitido pelo Let's Encrypt usando o desafio **TLS-ALPN-01** (sem depender da porta 80).  
Toda a automacao roda via `make`, com cada alvo delegando a scripts dedicados em `scripts/`.

## Requisitos
- Ubuntu (testado no 22.04) rodando na sua instancia OCI.
- Apenas as portas 22 (SSH) e 443 (HTTPS) precisam estar liberadas.
- Um dominio ou subdominio apontando para o IP publico da instancia.
- Usuario com permissao sudo (os scripts sobem pacotes e editam `/etc/nginx`).
- Nginx **nao** deve estar em uso durante o `make config`, pois o certbot abre um servidor standalone na 443 para validar o certificado.

## Fluxo principal
```bash
# 1. Instala dependencias do sistema (nginx, certbot, etc.)
make install

# 2. Gera certificado TLS via Let's Encrypt e cria a configuracao do Cobweb
make config

# 3. Valida configuracao e inicia/recarrega o Nginx
make run
```

### O que cada etapa faz
- `make install`  
  - Atualiza os indices do apt e instala `nginx` e `snapd`.  
  - Instala o `certbot` via **snap** (versao com suporte ao desafio TLS-ALPN-01) e cria o link `/usr/bin/certbot`.  
  - Remove o site padrao do Nginx e garante que o servico esteja parado, pronto para novas configuracoes.

- `make config`  
  - Solicita dominio, email e rotas que serao expostas (raiz `/` e caminhos adicionais, ex: `/api/`).  
  - Emite/renova certificado com `certbot certonly --standalone --preferred-challenges tls-alpn-01`.  
  - Gera a configuracao local em `config/cobweb.conf` e replica o arquivo para `/etc/nginx/sites-available/cobweb.conf`, criando o link simbólico em `sites-enabled`.  
  - Executa `nginx -t` para validar o arquivo.

- `make run`  
  - Revalida a configuracao (`nginx -t`) e inicia ou recarrega o servico `nginx`.  
  - Mostra um resumo do status (`systemctl status nginx --lines=3`).

Operacoes complementares:
```bash
make stop     # para o Nginx
make restart  # executa nginx -t e systemctl restart nginx
```

## Ajustando rotas e upstreams
- Todas as informacoes ficam salvas em `config/settings.json`.  
- Para editar ou adicionar rotas, execute `make config` novamente; o script reaproveita os valores atuais como padrao.  
- Para rotas baseadas em caminho (ex: `/admin/`), deixe o caminho terminar com `/` para evitar duplicacao de path na origem.  
- Se nao definir um upstream para `/`, o Cobweb responde `404` na raiz.

## Estrutura gerada
```
.
├─ Makefile
├─ README.md
├─ .gitignore
├─ scripts/
│  ├─ install.sh    # instala dependencias
│  ├─ config.py     # coleta dados, emite certificado e escreve o nginx.conf
│  ├─ run.sh        # valida e inicia/recarrega o nginx
│  ├─ stop.sh       # para o nginx
│  └─ restart.sh    # reinicia o nginx
├─ templates/
│  └─ cobweb.conf.tpl  # template do servidor HTTPS
└─ config/
   ├─ cobweb.conf      # (gerado) configuracao ativa usada no nginx
   └─ settings.json    # (gerado) cache das respostas do wizard
```

Arquivos gerados (`config/cobweb.conf` e `config/settings.json`) estao listados no `.gitignore` para evitar expor dados sensiveis do ambiente.

## Renovacao do certificado
O certbot ja guarda o certificado em `/etc/letsencrypt/live/<dominio>/`. Para renovar automaticamente sem abrir a porta 80, use o mesmo desafio TLS-ALPN:

```
sudo certbot renew --preferred-challenges tls-alpn-01 --deploy-hook "systemctl reload nginx"
```

Recomenda-se criar um cron (`/etc/cron.d/cobweb-renew`) ou um timer do systemd chamando o comando acima diariamente. O certbot so tenta renovar quando o certificado estiver proximo de expirar.

## Verificando conectividade
Depois do `make run`, valide:
- `sudo nginx -t` deve seguir retornando `syntax is ok`.
- `sudo systemctl status nginx` exibe o servico como `active (running)`.
- `curl -I https://seu.dominio` deve responder com `200/302/404` conforme o upstream esperado (o handshake TLS prova que o certificado foi aplicado).

## Problemas comuns
- **Certbot falha afirmando que a porta 443 esta em uso:** certifique-se de que `make stop` foi executado (ou que nenhum outro processo usa a porta).  
- **Dominio nao resolve:** confirme o registro DNS antes de emitir o certificado.  
- **Novas rotas nao entram em vigor:** rode `make config` e depois `make run` para reaplicar a configuracao.

## Proximos passos sugeridos
- Automatizar a renovacao com cron/timer.  
- Adicionar novas politicas de seguranca ao template (`rate-limit`, `deny`, etc.) conforme seu caso de uso.  
- Versionar um arquivo `config/settings.example.json` se quiser compartilhar configuracoes padrao sem dados reais.
