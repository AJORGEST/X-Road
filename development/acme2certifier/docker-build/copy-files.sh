#!/usr/bin/env bash
# copy-files.sh — Copia arquivos do testca-dev original para o docker-build
#
# Deve ser executado a partir da raiz do repositório X-Road:
#   bash development/acme2certifier/docker-build/copy-files.sh
#
# Ou a partir deste diretório (docker-build/):
#   bash copy-files.sh

set -euo pipefail

# ─── Cores ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✔${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $*"; }
err()  { echo -e "${RED}✖${RESET}  $*" >&2; }
info() { echo -e "${CYAN}→${RESET} $*"; }

# ─── Detectar raiz do repositório ─────────────────────────────────────────────
# Funciona tanto chamado da raiz quanto de dentro do docker-build/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

SRC="$REPO_ROOT/development/docker/testca-dev"
DST="$SCRIPT_DIR"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║        copy-files.sh — Passo 1 do docker-build       ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
info "Repositório : $REPO_ROOT"
info "Origem (SRC): $SRC"
info "Destino (DST): $DST"
echo ""

# ─── Verificar que o source existe ────────────────────────────────────────────
if [[ ! -d "$SRC" ]]; then
  err "Diretório de origem não encontrado: $SRC"
  err "Execute este script a partir da raiz do repositório X-Road ou de dentro de docker-build/."
  exit 1
fi

# ─── Lista de arquivos a copiar ───────────────────────────────────────────────
declare -A COPIES=(
  ["$SRC/files/ca-entrypoint.sh"]="$DST/files/ca-entrypoint.sh"
  ["$SRC/files/ca-xroad.conf"]="$DST/files/ca-xroad.conf"
  ["$SRC/files/acme2certifier/openssl_ca_handler.py"]="$DST/files/acme2certifier/openssl_ca_handler.py"
  ["$SRC/init.sh"]="$DST/files/home/ca/CA/init.sh"
)

declare -a DIRS_TO_COPY=(
  "$SRC/files/home"
  "$SRC/files/etc"
)

# ─── Verificar arquivos já existentes ─────────────────────────────────────────
OVERWRITE_LIST=()

for src_file in "${!COPIES[@]}"; do
  dst_file="${COPIES[$src_file]}"
  if [[ -e "$dst_file" ]]; then
    OVERWRITE_LIST+=("$dst_file")
  fi
done

for dir in "${DIRS_TO_COPY[@]}"; do
  dir_name=$(basename "$dir")
  dst_dir="$DST/files/$dir_name"
  if [[ -d "$dst_dir" ]]; then
    OVERWRITE_LIST+=("$dst_dir/")
  fi
done

if [[ ${#OVERWRITE_LIST[@]} -gt 0 ]]; then
  warn "Os seguintes itens já existem e serão sobrescritos:"
  for item in "${OVERWRITE_LIST[@]}"; do
    echo "    $item"
  done
  echo ""
  read -r -p "  Continuar? [s/N] " CONFIRM
  echo ""
  if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
    info "Operação cancelada."
    exit 0
  fi
fi

# ─── Criar diretórios de destino ──────────────────────────────────────────────
mkdir -p "$DST/files/acme2certifier"
mkdir -p "$DST/files/home/ca/CA"

# ─── Copiar arquivos individuais ──────────────────────────────────────────────
echo -e "${BOLD}Copiando arquivos...${RESET}"
echo ""

for src_file in "${!COPIES[@]}"; do
  dst_file="${COPIES[$src_file]}"
  if [[ ! -f "$src_file" ]]; then
    err "Arquivo de origem não encontrado: $src_file"
    exit 1
  fi
  cp "$src_file" "$dst_file"
  rel_src="${src_file#$REPO_ROOT/}"
  rel_dst="${dst_file#$REPO_ROOT/}"
  ok "$rel_src  →  $rel_dst"
done

# ─── Copiar diretórios ────────────────────────────────────────────────────────
for dir in "${DIRS_TO_COPY[@]}"; do
  if [[ ! -d "$dir" ]]; then
    err "Diretório de origem não encontrado: $dir"
    exit 1
  fi
  cp -r "$dir" "$DST/files/"
  rel_src="${dir#$REPO_ROOT/}"
  dir_name=$(basename "$dir")
  rel_dst="${DST#$REPO_ROOT/}/files/$dir_name/"
  ok "$rel_src/  →  $rel_dst"
done

# ─── Resumo ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✔ Cópia concluída com sucesso!${RESET}"
echo ""
echo -e "${YELLOW}⚠  Atenção:${RESET}"
echo "   files/home/ca/CA/private/ca.key.pem é uma chave de CA de DESENVOLVIMENTO."
echo "   Para produção, gere uma nova chave após o build com init.sh."
echo ""
echo -e "${BOLD}Próximo passo:${RESET}"
echo "   cp $DST/.env.example $DST/.env"
echo "   # edite o .env com o nome da CA do cliente"
echo "   bash $DST/build.sh"
echo ""
