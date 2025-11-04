#!/usr/bin/env python3

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


PROJECT_ROOT = Path(__file__).resolve().parent.parent
CONFIG_DIR = PROJECT_ROOT / "config"
SETTINGS_PATH = CONFIG_DIR / "settings.json"
LOCAL_NGINX_CONF = CONFIG_DIR / "cobweb.conf"
TEMPLATE_PATH = PROJECT_ROOT / "templates" / "cobweb.conf.tpl"
REMOTE_NGINX_AVAILABLE = Path("/etc/nginx/sites-available/cobweb.conf")
REMOTE_NGINX_ENABLED = Path("/etc/nginx/sites-enabled/cobweb.conf")


def log(message: str) -> None:
    print(f"[cobweb][config] {message}")


def ensure_template_exists() -> None:
    if not TEMPLATE_PATH.exists():
        log(f"Erro: template nao encontrado em {TEMPLATE_PATH}")
        sys.exit(1)


def require_cmd(cmd: str) -> None:
    if shutil.which(cmd) is None:
        log(f"Erro: comando '{cmd}' nao esta disponivel no PATH.")
        sys.exit(1)


def find_certbot() -> str:
    snap_path = Path("/snap/bin/certbot")
    candidates: List[str] = []
    if snap_path.exists():
        candidates.append(str(snap_path))

    which_path = shutil.which("certbot")
    if which_path:
        candidates.append(which_path)

    if not candidates:
        log("Erro: certbot nao encontrado. Execute 'make install' antes de continuar.")
        sys.exit(1)

    selected = candidates[0]
    log(f"Usando certbot em {selected}")
    return selected


def detect_sudo() -> Optional[str]:
    if os.geteuid() == 0:
        return None
    require_cmd("sudo")
    return "sudo"


def build_cmd(sudo: Optional[str], *args: str) -> List[str]:
    parts: List[str] = []
    if sudo:
        parts.append(sudo)
    parts.extend(args)
    return parts


def run_cmd(sudo: Optional[str], *args: str, check: bool = True, **kwargs: Any) -> subprocess.CompletedProcess:
    return subprocess.run(build_cmd(sudo, *args), check=check, **kwargs)


def popen_cmd(sudo: Optional[str], *args: str, **kwargs: Any) -> subprocess.Popen:
    return subprocess.Popen(build_cmd(sudo, *args), **kwargs)


def prompt(text: str, default: Optional[str] = None, required: bool = False) -> str:
    while True:
        suffix = f" [{default}]" if default else ""
        value = input(f"{text}{suffix}: ").strip()

        if not value and default is not None:
            return default
        if not value and required:
            print("Valor obrigatorio. Tente novamente.")
            continue

        return value


def prompt_routes(existing: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    routes: List[Dict[str, Any]] = []

    default_root_upstream = None
    for route in existing:
        if route.get("path") == "/":
            default_root_upstream = route.get("upstream")
            break

    root_upstream = prompt(
        "Informe o upstream da raiz '/' (ex: http://127.0.0.1:3000). Deixe vazio para retornar 404",
        default=default_root_upstream,
        required=False,
    )

    if root_upstream:
        routes.append({"path": "/", "upstream": root_upstream})
    else:
        routes.append({"path": "/", "upstream": None})

    def route_exists(path: str) -> bool:
        return any(route["path"] == path for route in routes)

    existing_map = {route["path"]: route.get("upstream") for route in existing if route.get("path") != "/"}

    while True:
        add_more = prompt("Deseja adicionar uma nova rota? (s/n)", default="n", required=True).lower()
        if add_more not in {"s", "n"}:
            print("Responda com 's' ou 'n'.")
            continue
        if add_more == "n":
            break

        path = prompt("Caminho publico (ex: /api/ ou /grafana)", required=True)
        if not path.startswith("/"):
            print("O caminho deve iniciar com '/'.")
            continue
        if not path.endswith("/"):
            log("Recomendacao: termine caminhos com '/' para evitar duplicacao de path em proxy_pass.")

        if route_exists(path):
            print("Ja existe uma rota configurada com esse caminho.")
            continue

        upstream_default = existing_map.get(path)
        upstream = prompt("Upstream (ex: http://127.0.0.1:3001)", default=upstream_default, required=True)
        routes.append({"path": path, "upstream": upstream})

    return routes


def ensure_certificate(domain: str, email: str, sudo: Optional[str], certbot_bin: str) -> None:
    cert_path = Path(f"/etc/letsencrypt/live/{domain}/fullchain.pem")
    if cert_path.exists():
        log(f"Certificado Let's Encrypt encontrado em {cert_path}. Pulando emissao.")
        return

    log("Nenhum certificado encontrado. Iniciando emissao via desafio TLS-ALPN-01...")
    run_cmd(sudo, "systemctl", "stop", "nginx", check=False)

    args_base = [
        certbot_bin,
        "certonly",
        "--standalone",
        "-d",
        domain,
        "--agree-tos",
        "--email",
        email,
        "--non-interactive",
        "--keep-until-expiring",
    ]

    attempts = [
        ("tls-alpn-01", ["--preferred-challenges", "tls-alpn-01"]),
        ("tls-alpn", ["--preferred-challenges", "tls-alpn"]),
    ]

    last_rc = 1
    for label, extra in attempts:
        cmd = build_cmd(sudo, *(args_base + extra))
        log(f"Executando certbot com desafio '{label}'...")
        result = subprocess.run(cmd, capture_output=True, text=True)
        last_rc = result.returncode
        if result.returncode == 0:
            log("Certificado emitido com sucesso.")
            return

        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if "Unrecognized challenges" not in result.stderr:
            break

        log(f"Certbot nao reconheceu o desafio '{label}'. Tentando alternativa...")

    log("Falha ao emitir o certificado. Verifique logs do certbot e garanta que a porta 443 esteja livre.")
    sys.exit(last_rc or 1)


def render_routes(routes: List[Dict[str, Any]]) -> str:
    blocks: List[str] = []

    common_lines = """
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_redirect off;
        proxy_read_timeout 60s;
    """.strip("\n")

    for route in routes:
        path = route["path"]
        upstream = route.get("upstream")

        if path != "/" and not path.endswith("/"):
            log(f"Aviso: adicionando '/' ao final do proxy_pass para {path} para evitar duplicacao de path.")

        if upstream:
            proxy_url = upstream
            if path.endswith("/") and not upstream.endswith("/"):
                proxy_url = upstream.rstrip("/") + "/"
            block = f"""
    location {path} {{
        proxy_pass {proxy_url};
{common_lines}
    }}
"""
        else:
            block = f"""
    location {path} {{
        return 404;
    }}
"""
        blocks.append(block.strip("\n"))

    health_block = """
    location = /healthz {
        access_log off;
        return 204;
    }
""".strip("\n")

    blocks.append(health_block)
    return "\n\n".join(blocks)


def write_nginx_conf(context: Dict[str, Any], sudo: Optional[str]) -> None:
    template = TEMPLATE_PATH.read_text(encoding="utf-8")
    rendered = (
        template.replace("{{SERVER_NAME}}", context["domain"])
        .replace("{{SSL_CERT}}", context["ssl_cert"])
        .replace("{{SSL_CERT_KEY}}", context["ssl_cert_key"])
        .replace("{{ROUTE_BLOCKS}}", context["route_blocks"])
    )

    LOCAL_NGINX_CONF.write_text(rendered, encoding="utf-8")
    log(f"Configuracao gerada em {LOCAL_NGINX_CONF}.")

    with popen_cmd(
        sudo,
        "tee",
        str(REMOTE_NGINX_AVAILABLE),
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    ) as proc:
        proc.communicate(rendered)
        if proc.returncode not in (0, None):
            log(f"Falha ao escrever {REMOTE_NGINX_AVAILABLE}.")
            sys.exit(proc.returncode)

    if REMOTE_NGINX_ENABLED.exists() or REMOTE_NGINX_ENABLED.is_symlink():
        run_cmd(sudo, "rm", "-f", str(REMOTE_NGINX_ENABLED), check=False)

    run_cmd(sudo, "ln", "-s", str(REMOTE_NGINX_AVAILABLE), str(REMOTE_NGINX_ENABLED))
    run_cmd(sudo, "rm", "-f", "/etc/nginx/sites-enabled/default", check=False)

    log("Executando nginx -t para validar a configuracao...")
    run_cmd(sudo, "nginx", "-t")


def load_existing() -> Dict[str, Any]:
    if SETTINGS_PATH.exists():
        try:
            return json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            log(f"Arquivo {SETTINGS_PATH} invalido. Ignorando e recriando.")
    return {}


def save_settings(settings: Dict[str, Any]) -> None:
    SETTINGS_PATH.write_text(json.dumps(settings, indent=2), encoding="utf-8")
    log(f"Configuracoes persistidas em {SETTINGS_PATH}.")


def main() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    ensure_template_exists()
    certbot_bin = find_certbot()
    sudo = detect_sudo()

    existing = load_existing()
    domain = prompt("Dominio (FQDN) que apontara para o cobweb", default=existing.get("domain"), required=True)
    email = prompt("Email para notificacoes do Let's Encrypt", default=existing.get("email"), required=True)

    routes = prompt_routes(existing.get("routes", []))

    ensure_certificate(domain, email, sudo, certbot_bin)

    ssl_cert = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
    ssl_cert_key = f"/etc/letsencrypt/live/{domain}/privkey.pem"

    route_blocks = render_routes(routes)
    context = {
        "domain": domain,
        "email": email,
        "routes": routes,
        "ssl_cert": ssl_cert,
        "ssl_cert_key": ssl_cert_key,
        "route_blocks": route_blocks,
    }

    write_nginx_conf(context, sudo)
    save_settings({"domain": domain, "email": email, "routes": routes})
    log("Configuracao concluida. Utilize 'make run' para iniciar o Nginx.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Configuracao cancelada pelo usuario.")
        sys.exit(1)
