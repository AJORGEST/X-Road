# Velero — Plano de Instalação Segura no EKS eksmaringa-prod

> **Documento gerado em:** 2026-08-10  
> **Cluster:** eksmaringa-prod (EKS v1.36, sa-east-1)  
> **Account AWS:** 644266601430  
> **Impacto:** ZERO nos workloads existentes

---

## 1. Análise do Cluster Atual

### Infraestrutura

| Item | Valor |
|------|-------|
| Cluster | `eksmaringa-prod` (EKS v1.36) |
| Região | `sa-east-1` |
| Nodes | 8 (5× m5.xlarge, 1× m5ad.xlarge, 1× t3.medium, 1× m5.xlarge gitlabrunner) |
| Node Groups | `app-ng`, `gitlabrunner-ng`, `system-ng` |
| Gerenciamento | Rancher 2.x (cattle-system) |
| Ingress | Traefik (1 réplica, LB externo + interno) |
| CSI Drivers | `ebs.csi.aws.com`, `efs.csi.aws.com` |
| Storage Classes | `gp3` (default), `gp2` (legacy) |
| VolumeSnapshot CRDs | **NÃO instalados** |
| OIDC Provider | ✅ `528E99C01D7C09430FD05164143ECBDA` |

### Namespaces Críticos (com dados persistentes)

| Namespace | Workloads Principais | PVCs |
|-----------|---------------------|------|
| `plataforma-gov-prod` | Kafka (3×10Gi), MongoDB (50Gi), ClickHouse/SigNoz (50Gi), Prometheus (10Gi), Grafana (5Gi), MariaDB (10Gi), SmartPass CAs (3×10Gi), Uptime Portal (5Gi) | ~14 PVCs |
| `posthog-maringa-prod` | ClickHouse (100Gi), Kafka (20Gi), Postgres (20Gi), Elasticsearch (10Gi), SeaweedFS (50Gi), ObjectStorage (50Gi), Redis (5Gi), Zookeeper (2×20Gi) | ~9 PVCs |
| `x-via-openbao` | OpenBao HA (3× data 50Gi + 3× audit 10Gi) | 6 PVCs |
| `gitlab-runner` | Runner executors (sem PVC persistente) | 0 PVCs |

### Recursos Disponíveis (folga para Velero)

| Node | Instance | CPU% | MEM% |
|------|----------|------|------|
| ip-10-0-43-184 (m5ad.xlarge) | m5ad.xlarge | 1% | 13% |
| ip-10-0-32-26 (m5.xlarge) | m5.xlarge | 2% | 27% |
| ip-10-0-62-239 (m5.xlarge) | m5.xlarge | 3% | 36% |
| ip-10-0-53-145 (t3.medium) | t3.medium | 2% | 38% |

> **Conclusão:** Há capacidade de sobra para o Velero (consome ~256Mi RAM + 100m CPU).

---

## 2. Pré-requisitos Identificados

| Pré-requisito | Status | Ação Necessária |
|---------------|--------|-----------------|
| CSI EBS Driver | ✅ Instalado | Nenhuma |
| OIDC Provider para IRSA | ✅ Configurado | Nenhuma |
| Bucket S3 para backups | ❌ Não existe | **Criar** |
| IAM Role para Velero (IRSA) | ❌ Não existe | **Criar** |
| VolumeSnapshot CRDs | ❌ Não instalados | **Instalar** |
| VolumeSnapshotClass | ❌ Não existe | **Criar** |
| Namespace velero | ❌ Não existe | Criado automaticamente na instalação |

---

## 3. Plano de Instalação Segura (Passo a Passo)

### Fase 1 — Preparação AWS (fora do cluster)

#### 1.1. Criar bucket S3 com encriptação

```bash
# Criar bucket dedicado para backups Velero
aws s3api create-bucket \
  --bucket eksmaringa-prod-velero-backups \
  --region sa-east-1 \
  --create-bucket-configuration LocationConstraint=sa-east-1

# Habilitar versionamento (proteção contra deleção acidental)
aws s3api put-bucket-versioning \
  --bucket eksmaringa-prod-velero-backups \
  --versioning-configuration Status=Enabled

# Encriptação SSE-S3 (padrão)
aws s3api put-bucket-encryption \
  --bucket eksmaringa-prod-velero-backups \
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
  --bucket eksmaringa-prod-velero-backups \
  --public-access-block-configuration '{
    "BlockPublicAcls": true,
    "IgnorePublicAcls": true,
    "BlockPublicPolicy": true,
    "RestrictPublicBuckets": true
  }'

# Lifecycle: transição para IA em 30 dias, expirar em 180 dias (prod = retenção maior)
aws s3api put-bucket-lifecycle-configuration \
  --bucket eksmaringa-prod-velero-backups \
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
cat > /tmp/velero-prod-policy.json << 'EOF'
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
      "Resource": "arn:aws:s3:::eksmaringa-prod-velero-backups/*"
    },
    {
      "Sid": "VeleroS3ListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::eksmaringa-prod-velero-backups"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name VeleroEKSMaringaProd \
  --policy-document file:///tmp/velero-prod-policy.json \
  --description "Velero backup permissions for eksmaringa-prod cluster"
```

#### 1.3. Criar IAM Role com IRSA (sem credenciais estáticas)

```bash
# Variáveis
ACCOUNT_ID=644266601430
OIDC_ID=528E99C01D7C09430FD05164143ECBDA
NAMESPACE=velero
SERVICE_ACCOUNT=velero-server

# Trust policy para IRSA
cat > /tmp/velero-prod-trust-policy.json << EOF
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
  --role-name VeleroEKSMaringaProd \
  --assume-role-policy-document file:///tmp/velero-prod-trust-policy.json \
  --description "Velero IRSA role for eksmaringa-prod"

# Anexar a policy
aws iam attach-role-policy \
  --role-name VeleroEKSMaringaProd \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/VeleroEKSMaringaProd
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
cat > /tmp/velero-prod-values.yaml << 'EOF'
# === Velero Helm Values para eksmaringa-prod ===

# Configuração principal
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: eksmaringa-prod-velero-backups
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

  # Backup default settings
  defaultVolumesToFsBackup: false  # Usar CSI snapshots por padrão

# ServiceAccount com IRSA (sem credenciais estáticas!)
serviceAccount:
  server:
    create: true
    name: velero-server
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::644266601430:role/VeleroEKSMaringaProd"

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

# Plugin AWS (CSI está integrado no Velero 1.14+, não precisa de plugin separado)
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.11.0
    imagePullPolicy: IfNotPresent
    volumeMounts:
      - mountPath: /target
        name: plugins

# Schedules automáticos (PROD: retenção maior, horário diferente)
schedules:
  # Backup diário dos namespaces críticos
  daily-critical-namespaces:
    disabled: false
    schedule: "0 2 * * *"  # 02:00 BRT (05:00 UTC) — horário de menor uso
    useOwnerReferencesInBackup: false
    template:
      ttl: "336h"  # Retém por 14 dias (prod = 2x dev)
      storageLocation: default
      volumeSnapshotLocations:
        - default
      includedNamespaces:
        - plataforma-gov-prod
        - posthog-maringa-prod
        - x-via-openbao
        - gitlab-runner
      snapshotMoveData: false
  
  # Backup semanal completo (retém 60 dias)
  weekly-full:
    disabled: false
    schedule: "0 3 * * 0"  # Domingos 03:00 BRT (06:00 UTC)
    useOwnerReferencesInBackup: false
    template:
      ttl: "1440h"  # 60 dias (prod = 2x dev)
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
        - cattle-capi-system
        - cattle-turtles-system
        - cattle-ui-plugin-system
        - cattle-global-data
        - cattle-impersonation-system
        - cattle-local-user-passwords
        - cert-manager
        - traefik
      snapshotMoveData: false
EOF
```

#### 3.3. Instalar com Helm (dry-run primeiro!)

```bash
# ⚠️ DRY-RUN: Validar antes de aplicar
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --values /tmp/velero-prod-values.yaml \
  --version 8.2.0 \
  --dry-run

# Se dry-run OK, instalar de verdade:
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --values /tmp/velero-prod-values.yaml \
  --version 8.2.0 \
  --wait
```

### Fase 4 — Validação Pós-Instalação

```bash
# 4.1. Verificar pods Velero
kubectl get pods -n velero
# Esperado: velero-XXXX (Running) + node-agent-XXXX em cada node (8 pods)

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
# 5.1. Backup de um namespace menor primeiro (gitlab-runner)
velero backup create test-gitlab-runner-prod \
  --include-namespaces gitlab-runner \
  --wait

# 5.2. Verificar se completou
velero backup describe test-gitlab-runner-prod
velero backup logs test-gitlab-runner-prod

# 5.3. Teste de restore em namespace DIFERENTE (sem afetar produção!)
velero restore create test-restore-runner \
  --from-backup test-gitlab-runner-prod \
  --namespace-mappings gitlab-runner:gitlab-runner-restore-test \
  --wait

# 5.4. Verificar o restore
kubectl get all -n gitlab-runner-restore-test

# 5.5. Limpar namespace de teste
kubectl delete namespace gitlab-runner-restore-test

# 5.6. Se tudo OK, testar backup com volumes (x-via-openbao — mais isolado)
velero backup create test-openbao-prod \
  --include-namespaces x-via-openbao \
  --wait

# 5.7. Verificar volumes no backup
velero backup describe test-openbao-prod --details
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

---

## 5. Estratégia de Backup Recomendada (Produção)

### Política de Retenção

| Tipo | Frequência | Retenção | Escopo |
|------|-----------|----------|--------|
| Diário | 02:00 BRT | 14 dias | Namespaces críticos |
| Semanal | Domingos 03:00 BRT | 60 dias | Cluster completo (exceto system) |
| Antes de mudanças | Manual | 60 dias | Namespace alvo |

### Namespaces Prioritários

1. **plataforma-gov-prod** — MongoDB 50Gi, Kafka 30Gi, ClickHouse/SigNoz 50Gi, MariaDB 10Gi, SmartPass CAs
2. **posthog-maringa-prod** — ClickHouse 100Gi, Postgres 20Gi, Kafka 20Gi, SeaweedFS 50Gi
3. **x-via-openbao** — Vault HA (3× data 50Gi + 3× audit 10Gi) — **CRÍTICO: secrets**
4. **gitlab-runner** — Configuração dos runners (sem dados persistentes)

### Volumes: CSI Snapshot vs File-Level (Kopia)

| Método | Quando usar | Vantagem |
|--------|-------------|----------|
| CSI Snapshot (EBS) | Volumes grandes (>20Gi), databases | Rápido, incremental, zero I/O no pod |
| Kopia (file-level) | Volumes pequenos, dados que precisam de portabilidade | Funciona cross-region, independente de cloud |

> **Recomendação PROD:** CSI Snapshots para databases (MongoDB, Postgres, ClickHouse, Kafka, OpenBao) e Kopia apenas se necessário para DR cross-region.

---

## 6. Comandos Úteis do Dia a Dia

```bash
# Ver todos os backups
velero backup get

# Criar backup manual antes de uma mudança (deploy, upgrade, etc)
velero backup create pre-deploy-$(date +%Y%m%d-%H%M) \
  --include-namespaces plataforma-gov-prod \
  --wait

# Ver schedules
velero schedule get

# Pausar schedule (manutenção)
velero schedule pause daily-critical-namespaces

# Retomar schedule
velero schedule unpause daily-critical-namespaces

# Restore completo de um namespace
velero restore create restore-plataforma \
  --from-backup daily-critical-namespaces-20260810050000 \
  --include-namespaces plataforma-gov-prod \
  --wait

# Restore de recurso específico
velero restore create restore-mongodb \
  --from-backup daily-critical-namespaces-20260810050000 \
  --include-namespaces plataforma-gov-prod \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --selector app=mongodb \
  --wait

# Deletar backup antigo manualmente
velero backup delete test-gitlab-runner-prod --confirm
```

---

## 7. Notificações Google Chat (Backup Success/Failure)

### 7.1. Criar Webhook no Google Chat

1. No Google Chat, abrir o **Space** onde deseja receber alertas
2. Clicar no nome do Space → **Apps & integrations** → **Manage webhooks**
3. Clicar **Add another** → Nome: `Velero Prod Backups` → Criar
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

    # Lê a URL do webhook do volume montado
    WEBHOOK_URL=$(cat /secrets/webhook-url)
    
    # Parâmetros recebidos do Velero (via env vars no CronJob)
    CLUSTER="eksmaringa-prod"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Busca o último backup e seu status
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
    
    BACKUP_NAME=$(echo "$LAST_BACKUP" | cut -d'|' -f1)
    PHASE=$(echo "$LAST_BACKUP" | cut -d'|' -f2)
    ERRORS=$(echo "$LAST_BACKUP" | cut -d'|' -f3)
    WARNINGS=$(echo "$LAST_BACKUP" | cut -d'|' -f4)
    STARTED=$(echo "$LAST_BACKUP" | cut -d'|' -f5)
    COMPLETED=$(echo "$LAST_BACKUP" | cut -d'|' -f6)
    
    # Define emoji e cor baseado no status
    if [ "$PHASE" = "Completed" ] && [ "$ERRORS" = "0" ]; then
      EMOJI="✅"
      STATUS_TEXT="SUCESSO"
      COLOR="#34A853"
    elif [ "$PHASE" = "Completed" ] && [ "$ERRORS" != "0" ]; then
      EMOJI="⚠️"
      STATUS_TEXT="PARCIAL (com erros)"
      COLOR="#FBBC04"
    elif [ "$PHASE" = "PartiallyFailed" ]; then
      EMOJI="⚠️"
      STATUS_TEXT="PARCIALMENTE FALHOU"
      COLOR="#FBBC04"
    else
      EMOJI="❌"
      STATUS_TEXT="FALHOU ($PHASE)"
      COLOR="#EA4335"
    fi
    
    # Monta payload Google Chat (Card v2)
    PAYLOAD=$(cat <<ENDJSON
    {
      "cardsV2": [
        {
          "cardId": "velero-backup-notification",
          "card": {
            "header": {
              "title": "${EMOJI} Velero Backup - ${STATUS_TEXT}",
              "subtitle": "Cluster: ${CLUSTER}",
              "imageUrl": "https://velero.io/img/Velero.svg",
              "imageType": "CIRCLE"
            },
            "sections": [
              {
                "header": "Detalhes do Backup",
                "widgets": [
                  {
                    "decoratedText": {
                      "topLabel": "Nome",
                      "text": "${BACKUP_NAME}"
                    }
                  },
                  {
                    "decoratedText": {
                      "topLabel": "Status",
                      "text": "<font color=\"${COLOR}\">${PHASE}</font>"
                    }
                  },
                  {
                    "decoratedText": {
                      "topLabel": "Erros / Warnings",
                      "text": "${ERRORS} erros, ${WARNINGS} warnings"
                    }
                  },
                  {
                    "decoratedText": {
                      "topLabel": "Início",
                      "text": "${STARTED}"
                    }
                  },
                  {
                    "decoratedText": {
                      "topLabel": "Conclusão",
                      "text": "${COMPLETED}"
                    }
                  }
                ]
              }
            ]
          }
        }
      ]
    }
    ENDJSON
    )
    
    # Envia para Google Chat
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

### 7.5. Criar CronJob de Notificação

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: velero-backup-notify
  namespace: velero
spec:
  # Executa 30 minutos após cada backup diário (02:30 BRT = 05:30 UTC)
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
# Notificação adicional para backup semanal (domingos 03:30 BRT = 06:30 UTC)
apiVersion: batch/v1
kind: CronJob
metadata:
  name: velero-backup-notify-weekly
  namespace: velero
spec:
  schedule: "30 6 * * 0"
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

### 7.7. Notificação Imediata via Velero Hooks (alternativa com BackupHook)

Para notificação **imediata** após cada backup (sem esperar CronJob), pode-se usar um controller como o [kubernetes-event-exporter](https://github.com/resmoio/kubernetes-event-exporter):

```bash
# Instalar event-exporter que escuta eventos do Velero e notifica Google Chat
# Esta é uma alternativa mais reativa que o CronJob
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: event-exporter-cfg
  namespace: velero
data:
  config.yaml: |
    logLevel: error
    route:
      routes:
        - match:
            - receiver: "gchat"
              involvedObject:
                apiVersion: "velero.io/v1"
                kind: "Backup"
              reason: "BackupCompleted|BackupFailed|BackupPartiallyFailed"
    receivers:
      - name: "gchat"
        webhook:
          endpoint: "WEBHOOK_URL_AQUI"
          headers:
            Content-Type: application/json
          layout:
            text: |
              *Velero Backup - eksmaringa-prod*
              📋 Backup: {{ .InvolvedObject.Name }}
              {{ if eq .Reason "BackupCompleted" }}✅ Status: Completado{{ else }}❌ Status: {{ .Reason }}{{ end }}
              ⏰ {{ .LastTimestamp }}
EOF
```

> **Recomendação:** Comece com o CronJob (seção 7.5) que é mais simples e confiável. Migre para event-exporter se precisar de notificação em tempo real.

---

## 8. Checklist de Execução

```
[✅] 1. Criar bucket S3 (eksmaringa-prod-velero-backups) — DONE 2026-08-10
[✅] 2. Configurar encriptação + versionamento + lifecycle (180 dias) — DONE 2026-08-10
[✅] 3. Criar IAM Policy (VeleroEKSMaringaProd) — DONE 2026-08-10
[✅] 4. Criar IAM Role com IRSA trust (OIDC: 528E99C01D7C09430FD05164143ECBDA) — DONE 2026-08-10
[✅] 5. Instalar VolumeSnapshot CRDs (v8.2.0) — DONE 2026-08-10
[✅] 6. Criar VolumeSnapshotClass (ebs-csi-snapclass) — DONE 2026-08-10
[✅] 7. Instalar Velero via Helm (chart 12.1.0, app v1.18.1) — DONE 2026-08-10
[✅] 8. Verificar pods + BSL disponível — DONE (BSL Available)
[✅] 9. Backup de teste (gitlab-runner, 20 itens, 2s) — DONE 2026-08-10
[✅] 10. Backup de teste com volumes (x-via-openbao, 76 itens, 6 CSI snapshots) — DONE 2026-08-10
[✅] 11. Schedules automáticos ativados — daily (05:00 UTC) + weekly (dom 06:00 UTC)
[✅] 12. Criar webhook Google Chat — DONE 2026-08-10
[✅] 13. Criar Secret + ConfigMap + CronJob de notificação — DONE 2026-08-10
[✅] 14. Testar notificação Google Chat — DONE 2026-08-10 (card enviado com sucesso)
```

### Recursos criados

| Recurso | Nome |
|---------|------|
| Bucket S3 | `eksmaringa-prod-velero-backups` (sa-east-1) |
| IAM Policy | `arn:aws:iam::644266601430:policy/VeleroEKSMaringaProd` |
| IAM Role (IRSA) | `arn:aws:iam::644266601430:role/VeleroEKSMaringaProd` |
| Helm Release | `velero` (namespace: velero, chart: 12.1.0, app: v1.18.1) |
| VolumeSnapshotClass | `ebs-csi-snapclass` |
| Schedule diário | `velero-daily-critical-namespaces` (05:00 UTC, 14d retenção) |
| Schedule semanal | `velero-weekly-full` (dom 06:00 UTC, 60d retenção) |
| CronJob notificação diário | `velero-backup-notify` (05:30 UTC) |
| CronJob notificação semanal | `velero-backup-notify-weekly` (06:30 UTC domingos) |
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
aws s3 rb s3://eksmaringa-prod-velero-backups --force
aws iam detach-role-policy --role-name VeleroEKSMaringaProd \
  --policy-arn arn:aws:iam::644266601430:policy/VeleroEKSMaringaProd
aws iam delete-role --role-name VeleroEKSMaringaProd
aws iam delete-policy --policy-arn arn:aws:iam::644266601430:policy/VeleroEKSMaringaProd
```

---

## 10. Diferenças entre Dev e Prod

| Aspecto | eksmaringa-dev | eksmaringa-prod |
|---------|---------------|-----------------|
| Bucket | `eksmaringa-dev-velero-backups` | `eksmaringa-prod-velero-backups` |
| IAM Role | `VeleroEKSMaringaDev` | `VeleroEKSMaringaProd` |
| OIDC ID | `E06B843FFDFB450D2F97C7FB47B55420` | `528E99C01D7C09430FD05164143ECBDA` |
| Retenção diária | 7 dias | 14 dias |
| Retenção semanal | 30 dias | 60 dias |
| Lifecycle S3 | 90 dias expiração | 180 dias (com Glacier IR em 90d) |
| Horário backup diário | 03:00 BRT | 02:00 BRT |
| Namespaces backup | plataforma-gov-dev, gitlab, posthog-maringa, x-via-openbao, xvia-ss, testca | plataforma-gov-prod, posthog-maringa-prod, x-via-openbao, gitlab-runner |
| Notificações | ❌ Não configurado | ✅ Google Chat (webhook) |
| OpenBao | 1 réplica (10Gi audit) | HA 3 réplicas (3×50Gi data + 3×10Gi audit) |

---

## 11. Referências

- [Velero Docs](https://velero.io/docs/)
- [Velero AWS Plugin](https://github.com/vmware-tanzu/velero-plugin-for-aws)
- [EKS + Velero Best Practices](https://aws.github.io/aws-eks-best-practices/security/docs/data/)
- [CSI Snapshotter](https://github.com/kubernetes-csi/external-snapshotter)
- [Google Chat Webhooks](https://developers.google.com/workspace/chat/quickstart/webhooks)
