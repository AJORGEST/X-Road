# Velero — Plano de Instalação Segura no EKS ekspernambuco

> **Documento gerado em:** 2026-08-10  
> **Cluster:** ekspernambuco (EKS v1.36.2, sa-east-1)  
> **Account AWS:** 137068239900  
> **Impacto:** ZERO nos workloads existentes

---

## 1. Análise do Cluster Atual

### Infraestrutura

| Item | Valor |
|------|-------|
| Cluster | `ekspernambuco` (EKS v1.36.2) |
| Região | `sa-east-1` |
| Nodes | 15 (13× m5a.xlarge + 2× m5a.large) |
| Node Groups | `ekspernambuco-ng-m5axlarge` (13 nodes), `ekspernambuco-ng-observability` (2 nodes) |
| Zonas | `sa-east-1a`, `sa-east-1b` |
| Gerenciamento | Rancher 2.x (cattle-system, 2 réplicas) |
| Ingress | NGINX Ingress Controller (6 réplicas, LB externo) |
| CSI Drivers | `ebs.csi.aws.com`, `efs.csi.aws.com` |
| Storage Classes | `gp2-custom` (default, Retain), `gp2` (legacy), `ebs-wait` (legacy), `openbao-gp3-retain` (CSI) |
| VolumeSnapshot CRDs | **NÃO instalados** |
| OIDC Provider | ✅ `EEEF395C86B67FDC8FE4FEE1955279B3` |

### Namespaces Críticos (com dados persistentes)

| Namespace | Workloads Principais | PVCs | Volume Total |
|-----------|---------------------|------|--------------|
| `aplicacoes-prod-td` | Elasticsearch HA (3×30Gi), ClickHouse/SigNoz (100Gi), MariaDB (10Gi), SmartPass CAs (3×10Gi), Uptime Portal (5Gi+10Gi), Prometheus (2Gi), Zookeeper (8Gi) | 15 PVCs | ~277Gi |
| `prod-ati-sidecar-se` | X-Road Sidecar SE (archive 300Gi + config 50Gi) | 2 PVCs | ~350Gi |
| `prod-ati-sidecar-ge` | X-Road Sidecar GE (archive 50Gi + config 30Gi) | 2 PVCs | ~80Gi |
| `openbao` | OpenBao HA (3× data 50Gi + 3× audit 10Gi) | 6 PVCs | ~180Gi |
| `aplicacoes-dev-td` | MongoDB (10Gi), Elasticsearch (10Gi), Prometheus (20Gi), SmartPass CAs (3×10Gi), SonarQube (20Gi), CMS (10Gi), Uptime (5Gi+10Gi), Alertmanager (2Gi) | 12 PVCs | ~137Gi |
| `dev-ati-sidecar-ge` | X-Road Sidecar GE dev (archive 50Gi + config 25Gi) | 2 PVCs | ~75Gi |
| `dev-ati-sidecar-se` | X-Road Sidecar SE dev (archive 50Gi + config 20Gi) | 2 PVCs | ~70Gi |
| `mongodb` | MongoDB PE (8Gi) | 1 PVC | ~8Gi |
| `default` | SonarQube Postgres (20Gi), CS-PE (5Gi), SS (5Gi) | 3 PVCs | ~30Gi |
| `sidecar` | CS Server (5Gi) | 1 PVC | ~5Gi |
| `aplicacoes-hml-td` | Elasticsearch Portal (5Gi) | 1 PVC | ~5Gi |

> **Total:** ~47 PVCs, ~1.217Gi de dados persistentes

### Recursos Disponíveis (folga para Velero)

| Node | Instance | CPU% | MEM% |
|------|----------|------|------|
| ip-192-168-12-24 | m5a.large | 3% | 19% |
| ip-192-168-60-5 | m5a.xlarge | 7% | 52% |
| ip-192-168-4-246 | m5a.xlarge | 7% | 69% |
| ip-192-168-48-183 | m5a.xlarge | 12% | 37% |
| ip-192-168-14-126 | m5a.xlarge | 12% | 44% |

> **Conclusão:** Há capacidade de sobra para o Velero (consome ~256Mi RAM + 100m CPU).

---

## 2. Pré-requisitos Identificados

| Pré-requisito | Status | Ação Necessária |
|---------------|--------|-----------------|
| CSI EBS Driver | ✅ Instalado | Nenhuma |
| CSI EFS Driver | ✅ Instalado | Nenhuma |
| OIDC Provider para IRSA | ✅ Configurado | Nenhuma |
| Bucket S3 para backups | ❌ Não existe | **Criar** |
| IAM Role para Velero (IRSA) | ❌ Não existe | **Criar** |
| VolumeSnapshot CRDs | ❌ Não instalados | **Instalar** |
| Snapshot Controller | ❌ Não instalado | **Instalar** |
| VolumeSnapshotClass | ❌ Não existe | **Criar** |
| Namespace velero | ❌ Não existe | Criado automaticamente na instalação |

> **Nota importante:** A maioria das Storage Classes (`ebs-wait`, `gp2`, `gp2-custom`) usa o provisionador legado `kubernetes.io/aws-ebs` (in-tree). Apenas `openbao-gp3-retain` usa o driver CSI. Para CSI snapshots funcionarem com volumes legados, o Velero usará **Kopia (file-level backup)** como fallback. Volumes na SC `openbao-gp3-retain` suportam CSI snapshot nativo.


---

## 3. Plano de Instalação Segura (Passo a Passo)

### Fase 1 — Preparação AWS (fora do cluster)

#### 1.1. Criar bucket S3 com encriptação

```bash
# Criar bucket dedicado para backups Velero
aws s3api create-bucket \
  --bucket ekspernambuco-velero-backups \
  --region sa-east-1 \
  --create-bucket-configuration LocationConstraint=sa-east-1

# Habilitar versionamento (proteção contra deleção acidental)
aws s3api put-bucket-versioning \
  --bucket ekspernambuco-velero-backups \
  --versioning-configuration Status=Enabled

# Encriptação SSE-S3 (padrão)
aws s3api put-bucket-encryption \
  --bucket ekspernambuco-velero-backups \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }
    ]
  }'

# Bloquear acesso público
aws s3api put-public-access-block \
  --bucket ekspernambuco-velero-backups \
  --public-access-block-configuration '{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }'

# Lifecycle: transição para IA em 30 dias, expirar em 180 dias
aws s3api put-bucket-lifecycle-configuration \
  --bucket ekspernambuco-velero-backups \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "ExpireOldBackups",
        "Status": "Enabled",
        "Filter": {"Prefix": "backups/"},
        "Expiration": {"Days": 180}
      },
      {
        "ID": "TransitionToIA",
        "Status": "Enabled",
        "Filter": {"Prefix": "backups/"},
        "Transitions": [
          {"Days": 30, "StorageClass": "STANDARD_IA"},
          {"Days": 90, "StorageClass": "GLACIER_IR"}
        ]
      }
    ]
  }'
```

#### 1.2. Criar IAM Policy para Velero

```bash
cat > /tmp/velero-pe-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VeleroEC2Permissions",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVolumes",
        "ec2:DescribeSnapshots",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot"
      ],
      "Resource": "*"
    },
    {
      "Sid": "VeleroS3BucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::ekspernambuco-velero-backups/*"
    },
    {
      "Sid": "VeleroS3ListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::ekspernambuco-velero-backups"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name VeleroEKSPernambuco \
  --policy-document file:///tmp/velero-pe-policy.json \
  --description "Velero backup permissions for ekspernambuco cluster"
```

#### 1.3. Criar IAM Role com IRSA (sem credenciais estáticas)

```bash
# Variáveis
ACCOUNT_ID=137068239900
OIDC_ID=EEEF395C86B67FDC8FE4FEE1955279B3
NAMESPACE=velero
SERVICE_ACCOUNT=velero-server

# Trust policy para IRSA
cat > /tmp/velero-pe-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.sa-east-1.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.sa-east-1.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}",
          "oidc.eks.sa-east-1.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# Criar a role
aws iam create-role \
  --role-name VeleroEKSPernambuco \
  --assume-role-policy-document file:///tmp/velero-pe-trust-policy.json \
  --description "Velero IRSA role for ekspernambuco"

# Anexar a policy
aws iam attach-role-policy \
  --role-name VeleroEKSPernambuco \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/VeleroEKSPernambuco
```

### Fase 2 — Instalar VolumeSnapshot CRDs (pré-requisito para CSI snapshots)

```bash
# Instalar CRDs do VolumeSnapshot (v1, compatível com EKS 1.36)
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

# Instalar snapshot-controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/v8.2.0/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml

# Verificar
kubectl get crd | grep volumesnapshot
# Esperado: 3 CRDs (volumesnapshotclasses, volumesnapshotcontents, volumesnapshots)

kubectl get pods -n kube-system | grep snapshot
# Esperado: snapshot-controller-XXXX (Running)
```

#### Criar VolumeSnapshotClass para EBS

```bash
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ebs-csi-snapclass
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: ebs.csi.aws.com
deletionPolicy: Retain
EOF
```

### Fase 3 — Instalar Velero via Helm

#### 3.1. Adicionar repositório Helm

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update
```

#### 3.2. Criar values.yaml

```bash
cat > /tmp/velero-pe-values.yaml << 'EOF'
# === Velero Helm Values para ekspernambuco ===

# Configuração principal
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: ekspernambuco-velero-backups
      prefix: backups
      config:
        region: sa-east-1
  
  volumeSnapshotLocation:
    - name: default
      provider: aws
      config:
        region: sa-east-1

  # Usar Kopia como uploader de volumes (substitui Restic)
  uploaderType: kopia

  # Features
  features: EnableCSI

  # Backup default: usar Kopia (file-level) por padrão pois a maioria
  # dos volumes usa provisioner legado (kubernetes.io/aws-ebs)
  defaultVolumesToFsBackup: true

# ServiceAccount com IRSA (sem credenciais estáticas!)
serviceAccount:
  server:
    create: true
    name: velero-server
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::137068239900:role/VeleroEKSPernambuco"

# Não precisamos de credentials secret (usando IRSA)
credentials:
  useSecret: false

# Node Agent (DaemonSet para backup file-level com Kopia)
deployNodeAgent: true
nodeAgent:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 1024Mi

# Resources do Velero Server
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 512Mi

# Plugin AWS
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.11.0
    imagePullPolicy: IfNotPresent
    volumeMounts:
      - mountPath: /target
        name: plugins

# Schedules automáticos
schedules:
  # Backup diário dos namespaces críticos (produção)
  daily-critical-namespaces:
    disabled: false
    schedule: "0 2 * * *"  # 02:00 BRT (05:00 UTC) — horário de menor uso
    useOwnerReferencesInBackup: false
    template:
      ttl: "336h"  # Retém por 14 dias
      storageLocation: default
      volumeSnapshotLocations:
        - default
      includedNamespaces:
        - aplicacoes-prod-td
        - prod-ati-sidecar-ge
        - prod-ati-sidecar-se
        - openbao
        - mongodb
      snapshotMoveData: false
  
  # Backup diário dos namespaces de desenvolvimento
  daily-dev-namespaces:
    disabled: false
    schedule: "0 3 * * *"  # 03:00 BRT (06:00 UTC)
    useOwnerReferencesInBackup: false
    template:
      ttl: "168h"  # Retém por 7 dias (dev = menor retenção)
      storageLocation: default
      volumeSnapshotLocations:
        - default
      includedNamespaces:
        - aplicacoes-dev-td
        - aplicacoes-hml-td
        - dev-ati-sidecar-ge
        - dev-ati-sidecar-se
      snapshotMoveData: false

  # Backup semanal completo (retém 60 dias)
  weekly-full:
    disabled: false
    schedule: "0 4 * * 0"  # Domingos 04:00 BRT (07:00 UTC)
    useOwnerReferencesInBackup: false
    template:
      ttl: "1440h"  # 60 dias
      storageLocation: default
      volumeSnapshotLocations:
        - default
      includedNamespaces:
        - "*"
      excludedNamespaces:
        - kube-system
        - kube-public
        - kube-node-lease
        - cattle-system
        - cattle-fleet-system
        - cattle-fleet-local-system
        - cattle-fleet-clusters-system
        - cattle-provisioning-capi-system
        - cattle-dashboards
        - cattle-global-data
        - cattle-global-nt
        - cattle-impersonation-system
        - cattle-monitoring-system
        - cattle-ui-plugin-system
        - cert-manager
        - ingress-nginx
        - elastic-system
        - amazon-cloudwatch
        - aws-observability
        - fleet-default
        - fleet-local
        - local
      snapshotMoveData: false
EOF
```

#### 3.3. Instalar com Helm (dry-run primeiro!)

```bash
# ⚠️ DRY-RUN: Validar antes de aplicar
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --values /tmp/velero-pe-values.yaml \
  --version 8.2.0 \
  --dry-run

# Se dry-run OK, instalar de verdade:
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --values /tmp/velero-pe-values.yaml \
  --version 8.2.0 \
  --wait
```

### Fase 4 — Validação Pós-Instalação

```bash
# 4.1. Verificar pods Velero
kubectl get pods -n velero
# Esperado: velero-XXXX (Running) + node-agent-XXXX em cada node (15 pods de node-agent)

# 4.2. Verificar BackupStorageLocation
kubectl get backupstoragelocation -n velero
# Esperado: STATUS = Available

# 4.3. Verificar VolumeSnapshotLocation
kubectl get volumesnapshotlocation -n velero

# 4.4. Verificar conectividade S3 (via logs)
kubectl logs -n velero -l app.kubernetes.io/name=velero --tail=20

# 4.5. Instalar CLI do Velero (se não tiver)
brew install velero

# 4.6. Verificar status geral
velero version
velero backup-location get
velero snapshot-location get
```

### Fase 5 — Teste de Backup Seguro (sem impacto em produção)

```bash
# 5.1. Backup de um namespace menor primeiro (mongodb — 1 PVC, 8Gi)
velero backup create test-mongodb-pe \
  --include-namespaces mongodb \
  --wait

# 5.2. Verificar se completou
velero backup describe test-mongodb-pe
velero backup logs test-mongodb-pe

# 5.3. Teste de restore em namespace DIFERENTE (sem afetar produção!)
velero restore create test-restore-mongodb \
  --from-backup test-mongodb-pe \
  --namespace-mappings mongodb:mongodb-restore-test \
  --wait

# 5.4. Verificar o restore
kubectl get all -n mongodb-restore-test

# 5.5. Limpar namespace de teste
kubectl delete namespace mongodb-restore-test

# 5.6. Se tudo OK, testar backup com volumes maiores (openbao — 6 PVCs, 180Gi)
velero backup create test-openbao-pe \
  --include-namespaces openbao \
  --wait

# 5.7. Verificar volumes no backup
velero backup describe test-openbao-pe --details

# 5.8. Testar backup de namespace crítico de produção
velero backup create test-prod-sidecar-pe \
  --include-namespaces prod-ati-sidecar-ge \
  --wait

velero backup describe test-prod-sidecar-pe --details
```

---

## 4. Garantias de Segurança (Zero Impacto)

| Preocupação | Mitigação |
|-------------|-----------|
| Velero pode derrubar pods? | **NÃO** — Velero é read-only durante backup (lê API + snapshots) |
| Snapshot afeta performance do EBS? | Mínimo — snapshots EBS são incrementais e não bloqueantes |
| DaemonSet consome recursos? | node-agent usa limits (1 CPU, 1Gi RAM) e só ativa durante backup |
| IRSA vaza credenciais? | **NÃO** — tokens temporários via STS, sem chaves estáticas |
| Backup falha: afeta cluster? | **NÃO** — falha de backup é isolada no namespace velero |
| Restore sobrescreve produção? | Só se executado manualmente no **mesmo** namespace |
| Volumes legados (in-tree) suportam CSI snapshot? | Kopia (file-level) é usado como fallback para volumes com provisioner legado |

---

## 5. Estratégia de Backup Recomendada

### Política de Retenção

| Tipo | Frequência | Retenção | Escopo |
|------|-----------|----------|--------|
| Diário (PROD) | 02:00 BRT | 14 dias | Namespaces de produção |
| Diário (DEV) | 03:00 BRT | 7 dias | Namespaces de desenvolvimento |
| Semanal | Domingos 04:00 BRT | 60 dias | Cluster completo (exceto system) |
| Antes de mudanças | Manual | 60 dias | Namespace alvo |

### Namespaces Prioritários

1. **aplicacoes-prod-td** — Elasticsearch HA 3×30Gi, ClickHouse/SigNoz 100Gi, MariaDB 10Gi, SmartPass CAs — **CRÍTICO**
2. **prod-ati-sidecar-se** — X-Road archive 300Gi + config 50Gi — **MAIOR VOLUME**
3. **prod-ati-sidecar-ge** — X-Road archive 50Gi + config 30Gi
4. **openbao** — Vault HA (3× data 50Gi + 3× audit 10Gi) — **CRÍTICO: secrets**
5. **mongodb** — MongoDB PE (8Gi)
6. **aplicacoes-dev-td** — Ambiente dev com 12 PVCs

### Volumes: Kopia (File-Level) vs CSI Snapshot

| Método | Quando usar | Vantagem |
|--------|-------------|----------|
| Kopia (file-level) | Volumes com SC legada (`ebs-wait`, `gp2`, `gp2-custom`) — **MAIORIA neste cluster** | Funciona com qualquer provisioner, portabilidade cross-region |
| CSI Snapshot (EBS) | Volumes com SC `openbao-gp3-retain` (usa `ebs.csi.aws.com`) | Rápido, incremental, zero I/O no pod |

> **Recomendação:** `defaultVolumesToFsBackup: true` pois a maioria dos volumes usa provisioner legado. OpenBao pode usar CSI snapshot nativo via annotation `velero.io/csi-volumesnapshot-class: ebs-csi-snapclass` nos PVCs.

### Migração futura para CSI Snapshots

Para habilitar CSI snapshots em todos os volumes, seria necessário migrar as Storage Classes legadas para o driver `ebs.csi.aws.com`. Isso pode ser feito gradualmente:

```bash
# Exemplo: criar SC moderna equivalente à gp2-custom
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-csi-retain
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
```

---

## 6. Comandos Úteis do Dia a Dia

```bash
# Ver todos os backups
velero backup get

# Criar backup manual antes de uma mudança (deploy, upgrade, etc)
velero backup create pre-deploy-$(date +%Y%m%d-%H%M) \
  --include-namespaces aplicacoes-prod-td \
  --wait

# Ver schedules
velero schedule get

# Pausar schedule (manutenção)
velero schedule pause daily-critical-namespaces

# Retomar schedule
velero schedule unpause daily-critical-namespaces

# Restore completo de um namespace
velero restore create restore-prod-td \
  --from-backup daily-critical-namespaces-20260810050000 \
  --include-namespaces aplicacoes-prod-td \
  --wait

# Restore de recurso específico (ex: X-Road sidecar config)
velero restore create restore-sidecar-config \
  --from-backup daily-critical-namespaces-20260810050000 \
  --include-namespaces prod-ati-sidecar-se \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --selector app.kubernetes.io/component=config \
  --wait

# Restore em namespace diferente (teste seguro)
velero restore create test-restore \
  --from-backup daily-critical-namespaces-20260810050000 \
  --include-namespaces openbao \
  --namespace-mappings openbao:openbao-restore-test \
  --wait

# Deletar backup antigo manualmente
velero backup delete test-mongodb-pe --confirm
```

---

## 7. Notificações Google Chat (Backup Success/Failure)

### 7.1. Criar Webhook no Google Chat

1. No Google Chat, abrir o **Space** onde deseja receber alertas
2. Clicar no nome do Space → **Apps & integrations** → **Manage webhooks**
3. Clicar **Add another** → Nome: `Velero PE Backups` → Criar
4. Copiar a URL do webhook (formato: `https://chat.googleapis.com/v1/spaces/XXXX/messages?key=...&token=...`)

### 7.2. Criar Secret com a URL do Webhook

```bash
# Substituir pela URL real do webhook
WEBHOOK_URL="https://chat.googleapis.com/v1/spaces/SPACE_ID/messages?key=KEY&token=TOKEN"

kubectl create secret generic velero-gchat-webhook \
  --from-literal=webhook-url="${WEBHOOK_URL}" \
  --namespace velero
```

### 7.3. Criar ConfigMap com o script de notificação

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: velero-notify-script
  namespace: velero
data:
  notify.sh: |
    #!/bin/sh
    set -e

    WEBHOOK_URL=$(cat /secrets/webhook-url)
    CLUSTER="ekspernambuco"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    LAST_BACKUP=$(velero backup get --output json 2>/dev/null | \
      python3 -c "
    import json, sys
    data = json.load(sys.stdin)
    items = data.get('items', [])
    if items:
        last = sorted(items, key=lambda x: x['metadata'].get('creationTimestamp',''), reverse=True)[0]
        name = last['metadata']['name']
        phase = last['status'].get('phase', 'Unknown')
        errors = last['status'].get('errors', 0)
        warnings = last['status'].get('warnings', 0)
        started = last['status'].get('startTimestamp', 'N/A')
        completed = last['status'].get('completionTimestamp', 'N/A')
        print(f'{name}|{phase}|{errors}|{warnings}|{started}|{completed}')
    else:
        print('none|NoBackups|0|0|N/A|N/A')
    ")
    
    BACKUP_NAME=\$(echo "\$LAST_BACKUP" | cut -d'|' -f1)
    PHASE=\$(echo "\$LAST_BACKUP" | cut -d'|' -f2)
    ERRORS=\$(echo "\$LAST_BACKUP" | cut -d'|' -f3)
    WARNINGS=\$(echo "\$LAST_BACKUP" | cut -d'|' -f4)
    STARTED=\$(echo "\$LAST_BACKUP" | cut -d'|' -f5)
    COMPLETED=\$(echo "\$LAST_BACKUP" | cut -d'|' -f6)
    
    if [ "\$PHASE" = "Completed" ] && [ "\$ERRORS" = "0" ]; then
      EMOJI="✅"; STATUS_TEXT="SUCESSO"; COLOR="#34A853"
    elif [ "\$PHASE" = "Completed" ] && [ "\$ERRORS" != "0" ]; then
      EMOJI="⚠️"; STATUS_TEXT="PARCIAL (com erros)"; COLOR="#FBBC04"
    elif [ "\$PHASE" = "PartiallyFailed" ]; then
      EMOJI="⚠️"; STATUS_TEXT="PARCIALMENTE FALHOU"; COLOR="#FBBC04"
    else
      EMOJI="❌"; STATUS_TEXT="FALHOU (\$PHASE)"; COLOR="#EA4335"
    fi
    
    PAYLOAD=$(cat <<ENDJSON
    {
      "cardsV2": [{
        "cardId": "velero-backup-notification",
        "card": {
          "header": {
            "title": "${EMOJI} Velero Backup - ${STATUS_TEXT}",
            "subtitle": "Cluster: ${CLUSTER}",
            "imageUrl": "https://velero.io/img/Velero.svg",
            "imageType": "CIRCLE"
          },
          "sections": [{
            "header": "Detalhes do Backup",
            "widgets": [
              {"decoratedText": {"topLabel": "Nome", "text": "${BACKUP_NAME}"}},
              {"decoratedText": {"topLabel": "Status", "text": "<font color=\"${COLOR}\">${PHASE}</font>"}},
              {"decoratedText": {"topLabel": "Erros / Warnings", "text": "${ERRORS} erros, ${WARNINGS} warnings"}},
              {"decoratedText": {"topLabel": "Início", "text": "${STARTED}"}},
              {"decoratedText": {"topLabel": "Conclusão", "text": "${COMPLETED}"}}
            ]
          }]
        }
      }]
    }
    ENDJSON
    )
    
    curl -s -X POST "${WEBHOOK_URL}" \
      -H "Content-Type: application/json" \
      -d "${PAYLOAD}"
    
    echo ""
    echo "[$(date)] Notificação enviada: ${STATUS_TEXT} - ${BACKUP_NAME}"
EOF
```

### 7.4. Criar ServiceAccount e RBAC para o CronJob

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: velero-notifier
  namespace: velero
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: velero-notifier
rules:
  - apiGroups: ["velero.io"]
    resources: ["backups", "schedules"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: velero-notifier
subjects:
  - kind: ServiceAccount
    name: velero-notifier
    namespace: velero
roleRef:
  kind: ClusterRole
  name: velero-notifier
  apiGroup: rbac.authorization.k8s.io
EOF
```

### 7.5. Criar CronJobs de Notificação

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: velero-backup-notify
  namespace: velero
spec:
  # Executa 30 min após backup diário prod (02:30 BRT = 05:30 UTC)
  schedule: "30 5 * * *"
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: velero-notifier
          containers:
            - name: notifier
              image: alpine/k8s:1.31.0
              command: ["/bin/bash", "/scripts/notify.sh"]
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                - name: webhook-secret
                  mountPath: /secrets
                  readOnly: true
              resources:
                requests:
                  cpu: 50m
                  memory: 64Mi
                limits:
                  cpu: 200m
                  memory: 128Mi
          restartPolicy: OnFailure
          volumes:
            - name: scripts
              configMap:
                name: velero-notify-script
                defaultMode: 0755
            - name: webhook-secret
              secret:
                secretName: velero-gchat-webhook
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: velero-backup-notify-weekly
  namespace: velero
spec:
  # Notificação para backup semanal (domingos 04:30 BRT = 07:30 UTC)
  schedule: "30 7 * * 0"
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: velero-notifier
          containers:
            - name: notifier
              image: alpine/k8s:1.31.0
              command: ["/bin/bash", "/scripts/notify.sh"]
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                - name: webhook-secret
                  mountPath: /secrets
                  readOnly: true
              resources:
                requests:
                  cpu: 50m
                  memory: 64Mi
                limits:
                  cpu: 200m
                  memory: 128Mi
          restartPolicy: OnFailure
          volumes:
            - name: scripts
              configMap:
                name: velero-notify-script
                defaultMode: 0755
            - name: webhook-secret
              secret:
                secretName: velero-gchat-webhook
EOF
```

### 7.6. Testar Notificação Manualmente

```bash
# Criar um job manual a partir do CronJob para testar
kubectl create job --from=cronjob/velero-backup-notify velero-notify-test -n velero

# Ver logs
kubectl logs -n velero -l job-name=velero-notify-test -f

# Limpar job de teste
kubectl delete job velero-notify-test -n velero
```

---

## 8. Checklist de Execução

```
[ ] 1. Criar bucket S3 (ekspernambuco-velero-backups)
[ ] 2. Configurar encriptação + versionamento + lifecycle (180 dias)
[ ] 3. Criar IAM Policy (VeleroEKSPernambuco)
[ ] 4. Criar IAM Role com IRSA trust (OIDC: EEEF395C86B67FDC8FE4FEE1955279B3)
[ ] 5. Instalar VolumeSnapshot CRDs (v8.2.0)
[ ] 6. Criar VolumeSnapshotClass (ebs-csi-snapclass)
[ ] 7. Instalar Velero via Helm (chart 8.2.0)
[ ] 8. Verificar pods + BSL disponível
[ ] 9. Backup de teste (mongodb — 1 PVC, 8Gi)
[ ] 10. Backup de teste com volumes maiores (openbao — 6 PVCs, 180Gi)
[ ] 11. Schedules automáticos ativados — daily prod (05:00 UTC) + daily dev (06:00 UTC) + weekly (dom 07:00 UTC)
[ ] 12. Criar webhook Google Chat
[ ] 13. Criar Secret + ConfigMap + CronJob de notificação
[ ] 14. Testar notificação Google Chat
```

### Recursos a serem criados

| Recurso | Nome |
|---------|------|
| Bucket S3 | `ekspernambuco-velero-backups` (sa-east-1) |
| IAM Policy | `arn:aws:iam::137068239900:policy/VeleroEKSPernambuco` |
| IAM Role (IRSA) | `arn:aws:iam::137068239900:role/VeleroEKSPernambuco` |
| Helm Release | `velero` (namespace: velero, chart: 8.2.0) |
| VolumeSnapshotClass | `ebs-csi-snapclass` |
| Schedule diário (prod) | `velero-daily-critical-namespaces` (05:00 UTC, 14d retenção) |
| Schedule diário (dev) | `velero-daily-dev-namespaces` (06:00 UTC, 7d retenção) |
| Schedule semanal | `velero-weekly-full` (dom 07:00 UTC, 60d retenção) |
| CronJob notificação diário | `velero-backup-notify` (05:30 UTC) |
| CronJob notificação semanal | `velero-backup-notify-weekly` (07:30 UTC domingos) |
| Secret webhook | `velero-gchat-webhook` |

---

## 9. Rollback (Remover Velero se necessário)

```bash
# Remover notificações
kubectl delete cronjob velero-backup-notify velero-backup-notify-weekly -n velero
kubectl delete configmap velero-notify-script -n velero
kubectl delete secret velero-gchat-webhook -n velero
kubectl delete clusterrolebinding velero-notifier
kubectl delete clusterrole velero-notifier
kubectl delete serviceaccount velero-notifier -n velero

# Remover Velero (não afeta workloads!)
helm uninstall velero -n velero
kubectl delete namespace velero

# Remover CRDs VolumeSnapshot (opcional)
kubectl delete crd \
  volumesnapshotclasses.snapshot.storage.k8s.io \
  volumesnapshotcontents.snapshot.storage.k8s.io \
  volumesnapshots.snapshot.storage.k8s.io

# Remover CRDs Velero (opcional)
kubectl delete crd \
  backups.velero.io \
  backupstoragelocations.velero.io \
  deletebackuprequests.velero.io \
  downloadrequests.velero.io \
  podvolumebackups.velero.io \
  podvolumerestores.velero.io \
  restores.velero.io \
  schedules.velero.io \
  serverstatusrequests.velero.io \
  volumesnapshotlocations.velero.io

# Remover recursos AWS
aws s3 rb s3://ekspernambuco-velero-backups --force
aws iam detach-role-policy --role-name VeleroEKSPernambuco \
  --policy-arn arn:aws:iam::137068239900:policy/VeleroEKSPernambuco
aws iam delete-role --role-name VeleroEKSPernambuco
aws iam delete-policy --policy-arn arn:aws:iam::137068239900:policy/VeleroEKSPernambuco
```

---

## 10. Diferenças entre Maringá Prod e Pernambuco

| Aspecto | eksmaringa-prod | ekspernambuco |
|---------|-----------------|---------------|
| Account AWS | `644266601430` | `137068239900` |
| Bucket | `eksmaringa-prod-velero-backups` | `ekspernambuco-velero-backups` |
| IAM Role | `VeleroEKSMaringaProd` | `VeleroEKSPernambuco` |
| OIDC ID | `528E99C01D7C09430FD05164143ECBDA` | `EEEF395C86B67FDC8FE4FEE1955279B3` |
| Nodes | 8 (m5.xlarge, m5ad.xlarge, t3.medium) | 15 (13× m5a.xlarge + 2× m5a.large) |
| Node Groups | `app-ng`, `gitlabrunner-ng`, `system-ng` | `ekspernambuco-ng-m5axlarge`, `ekspernambuco-ng-observability` |
| Ingress | Traefik | NGINX Ingress Controller (6 réplicas) |
| Storage Classes | `gp3` (default, CSI), `gp2` (legacy) | `gp2-custom` (default, legacy), `gp2`, `ebs-wait`, `openbao-gp3-retain` (CSI) |
| CSI nativo | Maioria dos volumes | Apenas `openbao-gp3-retain` |
| defaultVolumesToFsBackup | `false` (CSI snapshot) | `true` (Kopia, pois maioria é legado) |
| Total PVCs | ~29 PVCs | ~47 PVCs |
| Volume total | ~700Gi estimado | ~1.217Gi |
| Namespaces prod backup | 4 namespaces | 5 namespaces (prod) + 4 namespaces (dev) |
| Maior volume único | ClickHouse 100Gi | X-Road archive SE 300Gi |
| Horário backup prod | 02:00 BRT | 02:00 BRT |
| Horário backup dev | — | 03:00 BRT |
| Horário backup semanal | Dom 03:00 BRT | Dom 04:00 BRT |

---

## 11. Observações Específicas do Cluster ekspernambuco

### Storage Classes legadas

A maioria dos PVCs neste cluster usa provisioners legados (`kubernetes.io/aws-ebs`) que **não suportam CSI snapshots nativos**. Por isso:

1. **`defaultVolumesToFsBackup: true`** — O Velero usará Kopia (file-level backup) por padrão
2. **CSI Snapshot** só funciona para volumes na SC `openbao-gp3-retain` (driver `ebs.csi.aws.com`)
3. **Impacto:** Backups file-level são mais lentos mas funcionam universalmente
4. **Recomendação futura:** Migrar progressivamente para SCs com `ebs.csi.aws.com`

### Volume grande: prod-ati-sidecar-se (300Gi archive)

O maior volume individual é o archive do X-Road Sidecar SE (300Gi). Considerações:
- Backup file-level de 300Gi pode levar **30-60 minutos** na primeira execução
- Backups subsequentes são incrementais (Kopia deduplica)
- Monitorar uso de rede e I/O durante os primeiros backups

### OpenBao HA (6 PVCs, 180Gi total)

OpenBao é o workload mais crítico (secrets management):
- Usa SC `openbao-gp3-retain` com driver CSI → **suporta CSI snapshot nativo**
- Para forçar CSI snapshot no OpenBao (mesmo com `defaultVolumesToFsBackup: true`):

```bash
# Anotar PVCs do OpenBao para usar CSI snapshot ao invés de Kopia
kubectl annotate pvc -n openbao --all \
  velero.io/csi-volumesnapshot-class=ebs-csi-snapclass
```

---

## 12. Referências

- [Velero Docs](https://velero.io/docs/)
- [Velero AWS Plugin](https://github.com/vmware-tanzu/velero-plugin-for-aws)
- [EKS + Velero Best Practices](https://aws.github.io/aws-eks-best-practices/security/docs/data/)
- [CSI Snapshotter](https://github.com/kubernetes-csi/external-snapshotter)
- [Google Chat Webhooks](https://developers.google.com/workspace/chat/quickstart/webhooks)
- [Kopia Backup Engine](https://kopia.io/)
- [EBS CSI Driver - Volume Snapshots](https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/master/docs/snapshot.md)
