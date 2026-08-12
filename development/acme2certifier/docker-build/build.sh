#!/bin/bash
# =============================================================================
# build.sh — Build e push da imagem testca-dev personalizada (Opção B)
#
# Uso:
#   bash build.sh              # interativo, lê .env se existir
#   bash build.sh --no-push    # build sem push ECR
#   bash build.sh --push-only  # só push (imagem já existe localmente)
#
# Pré-requisitos:
#   - Docker instalado e rodando
#   - AWS CLI configurado (só para push ECR)
#   - Arquivos em files/ copiados do testca-dev original (ver README.md)
# =============================================================================
set -euo pipefail

# Cores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }
ask()   { echo -e "${BOLD}$1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
NO_PUSH=false
PUSH_ONLY=false
for arg in "$@"; do
  case $arg in
    --no-push)   NO_PUSH=true ;;
    --push-only) PUSH_ONLY=true ;;
  esac
done

# ---------------------------------------------------------------------------
# Carregar .env se existir
# ---------------------------------------------------------------------------
if [ -f .env ]; then
  info "Carregando variáveis de .env..."
  # shellcheck source=.env
  set -a; source .env; set +a
fi

# ---------------------------------------------------------------------------
# Valores padrão (usados se não vieram do .env)
# ---------------------------------------------------------------------------
CA_NAME="${CA_NAME:-Test CA}"
CA_ORG="${CA_ORG:-Test}"
OCSP_NAME="${OCSP_NAME:-Test OCSP}"
TSA_NAME="${TSA_NAME:-Test TSA}"
A2C_VER="${A2C_VER:-0.35}"
IMAGE_NAME="${IMAGE_NAME:-testca-dev}"
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
AWS_REGION="${AWS_REGION:-sa-east-1}"
ECR_ACCOUNT_ID="${ECR_ACCOUNT_ID:-}"

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}  Build testca-dev — Opção B (local)${NC}"
echo -e "${BOLD}============================================${NC}"
echo ""

if $PUSH_ONLY; then
  info "Modo --push-only: pulando o build."
else
  # -------------------------------------------------------------------------
  # Coleta interativa (só para campos não preenchidos no .env)
  # -------------------------------------------------------------------------
  echo -e "${BOLD}--- Personalização da CA ---${NC}"
  echo ""

  ask "Nome da CA (CN no certificado) [${CA_NAME}]: "
  read -r input; CA_NAME="${input:-$CA_NAME}"

  ask "Organização (O no certificado) [${CA_ORG}]: "
  read -r input; CA_ORG="${input:-$CA_ORG}"

  ask "Nome do OCSP [${OCSP_NAME}]: "
  read -r input; OCSP_NAME="${input:-$OCSP_NAME}"

  ask "Nome do TSA [${TSA_NAME}]: "
  read -r input; TSA_NAME="${input:-$TSA_NAME}"

  echo ""
  echo -e "${BOLD}--- Imagem Docker ---${NC}"
  echo ""

  ask "Nome da imagem [${IMAGE_NAME}]: "
  read -r input; IMAGE_NAME="${input:-$IMAGE_NAME}"

  ask "Tag da imagem [${IMAGE_TAG}]: "
  read -r input; IMAGE_TAG="${input:-$IMAGE_TAG}"

  # -------------------------------------------------------------------------
  # Verificar arquivos obrigatórios antes de buildar
  # -------------------------------------------------------------------------
  echo ""
  info "Verificando arquivos necessários..."

  MISSING=0
  REQUIRED_FILES=(
    "files/home/ca/CA/CA.cnf"
    "files/home/ca/CA/ca.py"
    "files/home/ca/CA/init.sh"
    "files/home/ca/CA/sign_req.sh"
    "files/home/ca/CA/ocsp.py"
    "files/home/ca/TSA/TSA.cnf"
    "files/home/ca/TSA/tsa_server.py"
    "files/etc/nginx/nginx.conf"
    "files/etc/nginx/sites-enabled/ca.nginx"
    "files/etc/nginx/sites-enabled/tsa.nginx"
    "files/acme2certifier/acme_srv.cfg"
    "files/acme2certifier/kid_profiles.json"
    "files/acme2certifier/openssl_ca_handler.py"
    "files/ca-entrypoint.sh"
    "files/ca-xroad.conf"
  )

  for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$f" ]; then
      warn "Faltando: $f"
      MISSING=$((MISSING + 1))
    fi
  done

  if [ $MISSING -gt 0 ]; then
    echo ""
    error "$MISSING arquivo(s) faltando. Execute os comandos de cópia do README.md antes de buildar."
  fi
  log "Todos os arquivos presentes."

  # -------------------------------------------------------------------------
  # Confirmação
  # -------------------------------------------------------------------------
  echo ""
  echo -e "${BOLD}============================================${NC}"
  echo -e "${BOLD}  Resumo do build${NC}"
  echo -e "${BOLD}============================================${NC}"
  echo ""
  echo "  Nome da CA:     ${CA_NAME}"
  echo "  Organização:    ${CA_ORG}"
  echo "  Nome OCSP:      ${OCSP_NAME}"
  echo "  Nome TSA:       ${TSA_NAME}"
  echo "  Imagem:         ${IMAGE_NAME}:${IMAGE_TAG}"
  echo "  acme2certifier: v${A2C_VER}"
  if [ -n "$ECR_ACCOUNT_ID" ] && ! $NO_PUSH; then
  echo "  Push ECR:       ${ECR_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_NAME}:${IMAGE_TAG}"
  else
  echo "  Push ECR:       não (--no-push ou ECR_ACCOUNT_ID vazio)"
  fi
  echo ""

  ask "Confirmar e iniciar build? (s/N): "
  read -r CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    echo "Cancelado."
    exit 0
  fi

  # -------------------------------------------------------------------------
  # Build
  # -------------------------------------------------------------------------
  echo ""
  info "Iniciando build..."
  echo ""

  docker build \
    -f Dockerfile.local \
    --build-arg CA_NAME="${CA_NAME}" \
    --build-arg CA_ORG="${CA_ORG}" \
    --build-arg OCSP_NAME="${OCSP_NAME}" \
    --build-arg TSA_NAME="${TSA_NAME}" \
    --build-arg A2C_VER="${A2C_VER}" \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -t "${IMAGE_NAME}:latest" \
    .

  echo ""
  log "Build concluído: ${IMAGE_NAME}:${IMAGE_TAG}"

  # -------------------------------------------------------------------------
  # Verificação rápida: checar se o nome foi aplicado no init.sh
  # -------------------------------------------------------------------------
  echo ""
  info "Verificando nome da CA na imagem..."
  BUILT_CN=$(docker run --rm --entrypoint="" "${IMAGE_NAME}:${IMAGE_TAG}" \
    grep "^DN_CA_CN=" /home/ca/CA/init.sh 2>/dev/null || echo "não encontrado")
  log "init.sh na imagem: ${BUILT_CN}"
fi

# ---------------------------------------------------------------------------
# Push ECR (opcional)
# ---------------------------------------------------------------------------
if $NO_PUSH; then
  info "Push ECR pulado (--no-push)."
  echo ""
elif [ -z "$ECR_ACCOUNT_ID" ]; then
  echo ""
  ask "Account ID da AWS para push ECR (deixe vazio para pular): "
  read -r input; ECR_ACCOUNT_ID="${input:-}"
fi

if [ -n "$ECR_ACCOUNT_ID" ] && ! $NO_PUSH; then
  ECR_REPO="${ECR_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  FULL_TAG="${ECR_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"
  FULL_TAG_LATEST="${ECR_REPO}/${IMAGE_NAME}:latest"

  echo ""
  info "Fazendo login no ECR (${AWS_REGION})..."
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REPO}"

  info "Criando repositório ECR se não existir..."
  aws ecr describe-repositories \
    --repository-names "${IMAGE_NAME}" \
    --region "${AWS_REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository \
    --repository-name "${IMAGE_NAME}" \
    --region "${AWS_REGION}" \
    --image-scanning-configuration scanOnPush=true \
    --query 'repository.repositoryUri' \
    --output text

  info "Tagueando imagem para ECR..."
  docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${FULL_TAG}"
  docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${FULL_TAG_LATEST}"

  info "Fazendo push..."
  docker push "${FULL_TAG}"
  docker push "${FULL_TAG_LATEST}"

  echo ""
  log "Push concluído!"
  echo ""
  echo -e "${BOLD}  URI da imagem no ECR:${NC}"
  echo "  ${FULL_TAG}"
  echo ""
  echo -e "${BOLD}  Usar no deployment.yaml / kustomization.yaml:${NC}"
  echo "  image: ${FULL_TAG}"
fi

# ---------------------------------------------------------------------------
# Resumo final
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}  Pronto!${NC}"
echo -e "${BOLD}============================================${NC}"
echo ""
echo "  Testar localmente:"
echo "    docker run -d --name testca -p 8887:8887 -p 8888:8888 -p 8899:8899 ${IMAGE_NAME}:${IMAGE_TAG}"
echo "    curl http://localhost:8887/acme/directory"
echo ""
echo "  Verificar nome da CA no certificado gerado:"
echo "    docker exec testca openssl x509 -in /home/ca/CA/certs/ca.cert.pem -subject -noout"
echo ""
if [ -n "$ECR_ACCOUNT_ID" ] && ! $NO_PUSH; then
echo "  Atualizar k8s-acme/kustomization.yaml:"
echo "    images:"
echo "      - name: testca-dev"
echo "        newName: ${ECR_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_NAME}"
echo "        newTag: \"${IMAGE_TAG}\""
echo ""
fi
