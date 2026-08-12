# O fluxo correto antes de fazer o deploy:

  # 1. Copiar a chave do container Docker existente:
  docker cp testca:/home/ca/CA/private/ca.key.pem ./ca.key.pem

  # 2. Criar o Secret diretamente no cluster (sem passar pelo arquivo/Git):
  kubectl create secret generic testca-ca-key \
    --from-file=ca.key.pem=./ca.key.pem \
    --namespace=testca

  # 3. Apagar o arquivo local:
  rm -f ./ca.key.pem

# k8s-acme — Manifests Kubernetes para testca-dev (ACME / OCSP / TSA)

Deploy do container `testca-dev` em Kubernetes com suporte ao X-Road via ACME (RFC 8555), OCSP e TSA.

## Arquitetura

```
X-Road Security Server
       │
       │  HTTPS :443
       ▼
Ingress Controller  (termina TLS)
       │
       ├── /acme/*  ──HTTP──►  Pod testca :8887  (acme2certifier)
       ├── /ocsp/*  ──HTTP──►  Pod testca :8888  (ca.py / OCSP)
       └── /tsa/*   ──HTTP──►  Pod testca :8899  (tsa_server.py)
```

### Volumes

| Volume | Tipo | Caminho no pod | Conteúdo |
|--------|------|---------------|----------|
| `testca-ca-data` | PVC (1Gi) | `/home/ca/CA/` | index.txt, serial, certs/, newcerts/, crl/, acme.sqlite3 |
| `testca-config` | ConfigMap | `/configs/` | acme_srv.cfg, kid_profiles.json |
| `testca-ca-key` | Secret | `/secrets/` | ca.key.pem |

---

## Pré-requisitos

- Kubernetes 1.24+
- `kubectl` configurado para o cluster
- `nginx-ingress-controller` instalado
- (Opcional) `cert-manager` para TLS automático via Let's Encrypt
- Imagem `testca-dev` disponível no registry do cluster

---

## Estrutura dos arquivos

```
k8s-acme/
├── namespace.yaml      # Namespace: testca
├── configmap.yaml      # acme_srv.cfg + kid_profiles.json
├── secret.yaml         # Template para ca.key.pem (preencher antes de aplicar)
├── pvc.yaml            # PersistentVolumeClaim 1Gi para /home/ca/CA/
├── deployment.yaml     # Deploy 1 réplica + initContainer + probes
├── service.yaml        # ClusterIP ports 8887, 8888, 8899
├── ingress.yaml        # nginx rewrite + TLS
├── kustomization.yaml  # Entry point para kubectl apply -k
└── README.md           # Este arquivo
```

---

## Deploy passo a passo

### 1. Preparar a chave privada da CA

A chave privada da CA **não está no repositório** por segurança. Você precisa fornecê-la antes do deploy.

**Opção A — Criar Secret diretamente (recomendado):**

```bash
# Obter a chave do container Docker existente:
docker cp testca:/home/ca/CA/private/ca.key.pem ./ca.key.pem

# Criar o Secret no cluster (sem passar pelo Git):
kubectl create namespace testca --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic testca-ca-key \
  --from-file=ca.key.pem=./ca.key.pem \
  --namespace=testca

# Remover o arquivo local após criar o Secret:
rm -f ./ca.key.pem
```

**Opção B — Editar secret.yaml (apenas para testes locais):**

```bash
# Codificar em base64:
base64 -w 0 ca.key.pem

# Substituir PLACEHOLDER_BASE64_DA_CHAVE_AQUI no secret.yaml
# ⚠️ NÃO commitar com o valor real
```

### 2. Ajustar configurações

Edite os arquivos antes de aplicar:

**ingress.yaml** — Substituir o domínio:
```bash
# Exemplo: substituir acme.xvia.com.br pelo domínio real
sed -i 's/acme.xvia.com.br/acme.seudominio.com.br/g' k8s-acme/ingress.yaml
```

**pvc.yaml** — Ajustar storageClassName:
```yaml
# Para AWS EKS com EBS gp3 (recomendado):
storageClassName: gp3

# Para Minikube / kind:
storageClassName: standard
```

**deployment.yaml** — Substituir a imagem:
```yaml
# Substituir em ambos os containers (initContainer e container principal):
image: 123456789.dkr.ecr.sa-east-1.amazonaws.com/testca-dev:1.0.0
```

**Ou via kustomization.yaml** (sem editar deployment.yaml):
```yaml
images:
  - name: testca-dev
    newName: 123456789.dkr.ecr.sa-east-1.amazonaws.com/testca-dev
    newTag: "1.0.0"
```

### 3. Dry-run (validar antes de aplicar)

```bash
# Validar cada arquivo individualmente:
kubectl apply -f k8s-acme/namespace.yaml  --dry-run=client
kubectl apply -f k8s-acme/configmap.yaml  --dry-run=client
kubectl apply -f k8s-acme/secret.yaml     --dry-run=client
kubectl apply -f k8s-acme/pvc.yaml        --dry-run=client
kubectl apply -f k8s-acme/deployment.yaml --dry-run=client
kubectl apply -f k8s-acme/service.yaml    --dry-run=client
kubectl apply -f k8s-acme/ingress.yaml    --dry-run=client

# OU validar tudo via kustomize:
kubectl apply -k k8s-acme/ --dry-run=client
```

### 4. Aplicar

```bash
# Criar o namespace primeiro (se ainda não existir):
kubectl apply -f k8s-acme/namespace.yaml

# Criar o Secret (se não criou na etapa 1):
kubectl apply -f k8s-acme/secret.yaml

# Aplicar tudo:
kubectl apply -k k8s-acme/

# Acompanhar o deploy:
kubectl rollout status deployment/testca -n testca
```

### 5. Verificar

```bash
# Pods rodando:
kubectl get pods -n testca

# Logs do initContainer (primeira inicialização):
kubectl logs -n testca -l app.kubernetes.io/name=testca -c init-ca-config

# Logs do container principal:
kubectl logs -n testca -l app.kubernetes.io/name=testca -c testca -f

# Service e Ingress:
kubectl get svc,ingress -n testca

# Testar ACME (de dentro do cluster):
kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://testca.testca.svc.cluster.local:8887/acme/directory
```

---

## Configurar no Central Server X-Road

Após o deploy, registrar a CA com as seguintes URLs:

| Campo | URL |
|-------|-----|
| ACME Directory URL | `https://acme.xvia.com.br/acme/directory` |
| OCSP URL | `https://acme.xvia.com.br/ocsp/` |
| TSA URL | `https://acme.xvia.com.br/tsa/` |

> Se usar a **Opção B** (3 hostnames separados):
> - ACME: `https://acme.xvia.com.br/acme/directory`
> - OCSP: `https://ocsp.xvia.com.br/`
> - TSA: `https://tsa.xvia.com.br/`

**Copiar certificados para upload no Central Server:**

```bash
POD=$(kubectl get pod -n testca -l app.kubernetes.io/name=testca -o jsonpath='{.items[0].metadata.name}')

kubectl cp testca/${POD}:/home/ca/CA/certs/ca.cert.pem   ./ca.cert.pem
kubectl cp testca/${POD}:/home/ca/CA/certs/ocsp.cert.pem ./ocsp.cert.pem
kubectl cp testca/${POD}:/home/ca/CA/certs/tsa.cert.pem  ./tsa.cert.pem
```

---

## Configurar local.yaml nos Security Servers

```yaml
xroad:
  acme: |
    eab-credentials:
      certificate-authorities:
        'Test CA':                          # ← nome exato da CA no Central Server
          mac-key-base64-encoded: true
          members:
            'DEV:COM:1234':                 # ← identificador do membro X-Road
              auth-kid: keyid_2
              auth-mac-key: addfdbb19965e85623c124a88d085eae50a7f7f4f570989e3a320a81c3119625
              sign-kid: keyid_3
              sign-mac-key: 96d7380f5ea8de06912a4520d0adca616848b5e70cb3d0bd748af5b33507ddde
    account-keystore-password: testPassword1234
```

> Os `mac-key` devem ser exatamente os `hmac` definidos no `kid_profiles.json` do ConfigMap.

---

## Bugs corrigidos (initContainer)

| # | Bug | Fix aplicado |
|---|-----|-------------|
| 1 | `init.sh` não adiciona CA cert ao `index.txt` → OCSP retorna "unknown" | initContainer executa o fix após `init.sh` |
| 2 | Arquivo serial do TSA não existe → warning e falhas concorrentes | initContainer cria `/home/ca/TSA/serial` |
| 3 | `eab_profiling: True` incompatível com X-Road 7.8 (acme4j) | ConfigMap já define `False`; initContainer garante via `sed` |

---

## TLS manual (sem cert-manager)

Se não tiver cert-manager, criar o Secret TLS manualmente:

```bash
# Certificado self-signed (apenas para teste):
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=acme.xvia.com.br"

kubectl create secret tls testca-tls-cert \
  --cert=tls.crt \
  --key=tls.key \
  --namespace=testca

rm -f tls.key tls.crt
```

> Com certificado self-signed, você precisará adicionar o certificado ao truststore Java
> de cada Security Server. Ver `INSTALACAO-COMPLETA.md`, seção 3.3 (`fix-ca-trust.sh`).

---

## Remover tudo

```bash
kubectl delete -k k8s-acme/

# O PVC NÃO é removido automaticamente (preserva os dados da CA):
kubectl delete pvc testca-ca-data -n testca
```

---

## Troubleshooting

### Pod em CrashLoopBackOff

```bash
# Ver logs do initContainer:
kubectl logs -n testca <pod> -c init-ca-config

# Ver logs do container principal:
kubectl logs -n testca <pod> -c testca
```

### OCSP retorna "unknown"

Verificar se o CA cert está no `index.txt`:

```bash
POD=$(kubectl get pod -n testca -l app.kubernetes.io/name=testca -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n testca $POD -- cat /home/ca/CA/index.txt
```

Deve conter uma linha com o serial da CA (entry `V`).

### ACME directory retorna 502 / 503

```bash
# Verificar se o pod está pronto:
kubectl get pod -n testca

# Verificar endpoints do service:
kubectl describe endpoints testca -n testca

# Testar diretamente no pod (bypass do Ingress):
kubectl port-forward svc/testca 8887:8887 -n testca
curl http://localhost:8887/acme/directory
```

### Erro "eab_credentials_missing" no X-Road

Verificar se `eab_profiling: False` está aplicado:

```bash
kubectl exec -n testca $POD -- grep eab_profiling \
  /var/www/acme2certifier/acme_srv/acme_srv.cfg
# Esperado: eab_profiling: False
```
