# docker-build — Build personalizado da CA (Opção B)

Build da imagem `testca-dev` sem dependência do mirror privado, com nome da CA configurável via variáveis.

O nome da CA é fixado em **build-time**: o `init.sh` roda durante o `docker build` e gera os certificados com o CN correto diretamente na imagem. Não é necessário volume limpo ou execução manual do `init.sh` no boot.

## Estrutura

```
docker-build/
├── Dockerfile.local              # Dockerfile sem mirror privado, com ARGs de personalização
├── build.sh                      # Script interativo de build + push ECR
├── copy-files.sh                 # Copia arquivos do testca-dev original para files/
├── .env.example                  # Variáveis de personalização (copiar para .env)
├── README.md                     # Este arquivo
└── files/
    ├── acme2certifier/
    │   ├── acme_srv.cfg           # eab_profiling: False (compatível com X-Road 7.8)
    │   ├── kid_profiles.json      # Perfis EAB (auth/sign) com HMACs
    │   └── openssl_ca_handler.py  # ← copiar do testca-dev original (ver Passo 1)
    ├── home/                      # ← copiar do testca-dev original (ver Passo 1)
    │   └── ca/
    │       ├── CA/  (CA.cnf, init.sh, ca.py, ocsp.py, sign_req.sh, ...)
    │       └── TSA/ (TSA.cnf, tsa_server.py, serial)
    ├── etc/                       # ← copiar do testca-dev original (ver Passo 1)
    │   └── nginx/
    │       ├── nginx.conf
    │       └── sites-enabled/ (ca.nginx, tsa.nginx)
    ├── ca-entrypoint.sh           # ← copiar do testca-dev original (ver Passo 1)
    └── ca-xroad.conf              # ← copiar do testca-dev original (ver Passo 1)
```

---

## Passo 1 — Copiar arquivos do testca-dev original

Os arquivos marcados com `← copiar` não estão nesta pasta por conterem chaves de CA.
Execute `copy-files.sh` uma vez para montar a estrutura completa:

```bash
bash development/acme2certifier/docker-build/copy-files.sh
```

> Pode ser chamado da raiz do repositório **ou** de dentro do próprio `docker-build/`:
> ```bash
> cd development/acme2certifier/docker-build
> bash copy-files.sh
> ```

O script copia automaticamente:
- `files/ca-entrypoint.sh`
- `files/ca-xroad.conf`
- `files/home/` (CA + TSA, com chaves de desenvolvimento)
- `files/etc/` (nginx)
- `files/acme2certifier/openssl_ca_handler.py`

Se algum arquivo já existir, o script lista os itens que serão sobrescritos e pede confirmação.

> ⚠️ `files/home/ca/CA/private/ca.key.pem` é uma chave de CA de **desenvolvimento**.
> Para produção, gere uma nova chave após o build com `init.sh`.

---

## Passo 2 — Configurar o .env

```bash
cp .env.example .env
```

Editar `.env`:

```bash
CA_NAME="Maringa CA"
CA_ORG="Maringa"
OCSP_NAME="Maringa OCSP"
TSA_NAME="Maringa TSA"
IMAGE_NAME="maringa-dev"
IMAGE_TAG="1.0.0"
AWS_REGION="sa-east-1"
ECR_ACCOUNT_ID="644222222" "Informe a conta correta"
```

O `CA_NAME` é o CN que aparecerá no certificado e no Central Server X-Road.
É também o nome que vai no `local.yaml` de cada Security Server.

---

## Passo 3 — Build

```bash
# Interativo (recomendado — lê .env e pede confirmação):
bash build.sh

# Build direto sem push:
bash build.sh --no-push

# Só push (imagem já existe localmente):
bash build.sh --push-only
```

O script:
1. Carrega as variáveis do `.env`
2. Verifica se todos os arquivos obrigatórios existem
3. Exibe o resumo e pede confirmação
4. Executa o `docker build` com os `--build-arg` corretos
5. Verifica que o nome foi aplicado no certificado gerado dentro da imagem
6. Faz login no ECR, cria o repositório se não existir e faz push

---

## Passo 4 — Testar localmente

```bash
# Subir o container:
docker run -d \
  --name testca \
  -p 8887:8887 \
  -p 8888:8888 \
  -p 8899:8899 \
  maringa-dev:1.0.0

# Aguardar inicialização (~10s) e testar:
curl http://localhost:8887/acme/directory

# Verificar o nome no certificado gerado:
docker exec testca openssl x509 \
  -in /home/ca/CA/certs/ca.cert.pem \
  -subject -noout
# subject=O = Maringa, CN = Maringa CA
```

---

## Passo 5 — Usar no Kubernetes (k8s-acme/)

Após o push ECR, atualizar `k8s-acme/kustomization.yaml`:

```yaml
images:
  - name: testca-dev
    newName: 6442222222.dkr.ecr.sa-east-1.amazonaws.com/maringa-dev
    newTag: "1.0.0"
```

Criar o Secret com a chave privada da CA:

```bash
# Extrair a chave do container local:
docker cp testca:/home/ca/CA/private/ca.key.pem ./ca.key.pem

# Criar o Secret no cluster:
kubectl create secret generic testca-ca-key \
  --from-file=ca.key.pem=./ca.key.pem \
  --namespace=testca

# Remover a chave local depois:
rm ca.key.pem
```

Aplicar:

```bash
kubectl apply -k k8s-acme/
```

O `initContainer` do deployment copia os arquivos da imagem para o PVC no primeiro boot (quando o PVC está vazio). Nos boots seguintes, o PVC já tem os dados e o initContainer é no-op.

---

## Como o nome da CA é aplicado

```
.env  →  build.sh  →  docker build --build-arg CA_NAME="Maringa CA"
                              │
                              ▼
                    Dockerfile.local
                    1. sed substitui DN_CA_CN no init.sh
                    2. rm .init (remove marcador pré-existente)
                    3. bash init.sh → gera ca.cert.pem com CN=Maringa CA
                              │
                              ▼
                    Imagem já contém certs com CN correto
                              │
                              ▼ (primeiro boot no k8s)
                    initContainer copia /home/ca/CA → PVC
                              │
                              ▼
                    Container principal usa PVC com certs corretos
```

O nome é fixado no momento do `docker build`. Trocar o nome exige rebuild da imagem.
No Kubernetes, também é necessário deletar o PVC para que o initContainer recrie o estado a partir da nova imagem.

---

## Personalizar os HMACs (produção)

Os `hmac` no `kid_profiles.json` são as senhas EAB dos Security Servers.
Para produção, gere novos:

```bash
openssl rand -hex 32   # → hmac para keyid_1 (genérico)
openssl rand -hex 32   # → hmac para keyid_2 (auth)
openssl rand -hex 32   # → hmac para keyid_3 (sign)
```

Atualizar `files/acme2certifier/kid_profiles.json` (e o ConfigMap em `k8s-acme/configmap.yaml`) e o `local.yaml` de cada Security Server com os valores correspondentes.

---

## Ingress — URLs no X-Road

O `k8s-acme/ingress.yaml` usa **3 Ingresses separados por hostname** (recomendado):

| Serviço | URL | Porta |
|---------|-----|-------|
| ACME | `https://acme.xvia.com.br/acme/directory` | 8887 |
| OCSP | `https://ocsp.xvia.com.br/` | 8888 |
| TSA  | `https://tsa.xvia.com.br/` | 8899 |

Registrar no Central Server X-Road com essas URLs exatas.

> Por que não usar path-based routing com rewrite?
> O acme2certifier espera receber o path `/acme/...` completo — um rewrite genérico
> com `rewrite-target: "/$2"` transformaria `/acme/directory` em `/directory`, quebrando
> todas as chamadas ACME. Com hostnames separados e `path: /`, cada serviço recebe
> o path exatamente como enviado pelo cliente.
