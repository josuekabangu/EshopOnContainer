ubuntu@ip-172-31-46-154:~/eShopOnContainer/EshopOnContainer$ helm template helm-chart
---
# Source: eshop/charts/catalog/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: release-name-catalog
  labels:
    helm.sh/chart: catalog-0.1.0
    app.kubernetes.io/name: catalog
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
automountServiceAccountToken: true
---
# Source: eshop/charts/catalogdb/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: release-name-catalogdb
  labels:
    helm.sh/chart: catalogdb-0.1.0
    app.kubernetes.io/name: catalogdb
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
automountServiceAccountToken: true
---
# Source: eshop/charts/rabbitmq/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: release-name-rabbitmq
  labels:
    helm.sh/chart: rabbitmq-0.1.0
    app.kubernetes.io/name: rabbitmq
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
automountServiceAccountToken: true
---
# Source: eshop/charts/redis/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: release-name-redis
  labels:
    helm.sh/chart: redis-0.1.0
    app.kubernetes.io/name: redis
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
automountServiceAccountToken: true
---
# Source: eshop/templates/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: release-name-eshop
  labels:
    helm.sh/chart: eshop-0.1.0
    app.kubernetes.io/name: eshop
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
automountServiceAccountToken: true
---
# Source: eshop/charts/basket/templates/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: release-name-secret
  namespace: dev
type: Opaque
stringData:
  redisHost: redis
  redisPort: 
  rabbitmqHost: 
  rabbitmqPort: 
  rabbitmqUsername: 
  rabbitmqPassword:
---
# Source: eshop/charts/catalog/templates/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: release-name-catalog-secret
  namespace: dev
  labels:
    helm.sh/chart: catalog-0.1.0
    app.kubernetes.io/name: catalog
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
type: Opaque
stringData:
  username: postgres
  password: postgres
---
# Source: eshop/charts/catalogdb/templates/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: release-name-catalogdb-secret
  namespace: dev
  labels:
    helm.sh/chart: catalogdb-0.1.0
    app.kubernetes.io/name: catalogdb
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
type: Opaque
stringData:
  username: postgres
  password: postgres
---
# Source: eshop/charts/rabbitmq/templates/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: release-name-rabbitmq-secret
  namespace: dev
  labels:
    helm.sh/chart: rabbitmq-0.1.0
    app.kubernetes.io/name: rabbitmq
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
type: Opaque
stringData:
  username: guest
  password: guest
---
# Source: eshop/charts/redis/templates/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: release-name-redis-secret
  namespace: dev
  labels:
    helm.sh/chart: redis-0.1.0
    app.kubernetes.io/name: redis
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
type: Opaque
stringData:
  password: default-redis-password
---
# Source: eshop/charts/basket/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: release-name-config
  namespace: dev
data:
  appsettings.json: |
    {
      "Logging": {
        "LogLevel": {
          "Default": "Information",
          "Microsoft": "Warning",
          "Microsoft.Hosting.Lifetime": "Information"
        }
      }
    }
---
# Source: eshop/charts/catalog/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: release-name-catalog-config
  namespace: dev
  labels:
    helm.sh/chart: catalog-0.1.0
    app.kubernetes.io/name: catalog
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
data:
  appsettings.json: |
    {
      "Database": {
        "Host": "{{ .Release.Name }}-catalogdb-postgresql-ha",
        "Name": "catalogdb"
      }
    }
---
# Source: eshop/charts/catalogdb/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: release-name-catalogdb-config
  namespace: dev
  labels:
    helm.sh/chart: catalogdb-0.1.0
    app.kubernetes.io/name: catalogdb
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
data:
  postgresql.conf: |
    listen_addresses = '*'
    port = 5432
---
# Source: eshop/charts/rabbitmq/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: release-name-rabbitmq-config
  namespace: dev
  labels:
    helm.sh/chart: rabbitmq-0.1.0
    app.kubernetes.io/name: rabbitmq
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
data:
  rabbitmq.conf: |
    default_vhost = /
    default_user = guest
    default_pass = guest
---
# Source: eshop/charts/redis/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: release-name-redis-config
  namespace: dev
  labels:
    helm.sh/chart: redis-0.1.0
    app.kubernetes.io/name: redis
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
data:
  redis.conf: |
    port 6379
    requirepass default-redis-password
---
# Source: eshop/charts/basket/templates/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: basket-data-protection-pvc
  namespace: dev
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
---
# Source: eshop/charts/basket/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: release-name
  namespace: dev
  labels:
    app.kubernetes.io/name: basket-api
    app.kubernetes.io/instance: release-name
spec:
  selector:
    app: basket-api
  type: NodePort
  ports:
    - protocol: TCP
      port: 5221
      targetPort: 5221
      nodePort: 30221
---
# Source: eshop/charts/catalog/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: release-name-catalog
  namespace: dev
  labels:
    helm.sh/chart: catalog-0.1.0
    app.kubernetes.io/name: catalog
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: catalog
    app.kubernetes.io/instance: release-name
---
# Source: eshop/charts/catalogdb/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: release-name-catalogdb
  namespace: dev
  labels:
    helm.sh/chart: catalogdb-0.1.0
    app.kubernetes.io/name: catalogdb
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
spec:
  type: ClusterIP
  ports:
    - port: 5432
      targetPort: 5432
      protocol: TCP
      name: postgres
  selector:
    app.kubernetes.io/name: postgresql-ha-postgresql
    app.kubernetes.io/instance: release-name
---
# Source: eshop/charts/rabbitmq/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: release-name-rabbitmq
  namespace: dev
  labels:
    helm.sh/chart: rabbitmq-0.1.0
    app.kubernetes.io/name: rabbitmq
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
spec:
  type: ClusterIP
  ports:
    - port: 5672
      targetPort: 5672
      protocol: TCP
      name: amqp
    - port: 15672
      targetPort: 15672
      protocol: TCP
      name: management
  selector:
    app.kubernetes.io/name: rabbitmq
    app.kubernetes.io/instance: release-name
---
# Source: eshop/charts/redis/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: release-name-redis
  namespace: dev
  labels:
    helm.sh/chart: redis-0.1.0
    app.kubernetes.io/name: redis
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
spec:
  type: ClusterIP
  ports:
    - port: 6379
      targetPort: 6379
      protocol: TCP
      name: redis
  selector:
    app.kubernetes.io/name: redis
    app.kubernetes.io/instance: release-name
---
# Source: eshop/templates/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: release-name-eshop
  labels:
    helm.sh/chart: eshop-0.1.0
    app.kubernetes.io/name: eshop
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app.kubernetes.io/name: eshop
    app.kubernetes.io/instance: release-name
---
# Source: eshop/charts/basket/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: release-name
  namespace: dev
  labels:
    app.kubernetes.io/name: basket-api
    app.kubernetes.io/instance: release-name
spec:
  replicas: 1
  selector:
    matchLabels:
      app: basket-api
  template:
    metadata:
      labels:
        app: basket-api
    spec:
      containers:
        - name: basket-api
          image: "docker.io/ajkabs/basket-api:latest"
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5221
          env:
            - name: ASPNETCORE_ENVIRONMENT
              value: "Development"
            - name: ASPNETCORE_URLS
              value: "http://*:5221"
            - name: ConnectionStrings__Redis
              value: "redis"
            - name: ConnectionStrings__EventBus
              valueFrom:
                secretKeyRef:
                  name: release-name-secret
                  key: eventBusConnection
            - name: Identity__Url
              value: "http://identity-api:5001"
            - name: DOTNET_READYTORUN
              value: "1"
            - name: DOTNET_TieredPGO
              value: "1"
            - name: DataProtection__Path
              value: "/app/keys"
          volumeMounts:
            - name: config-volume
              mountPath: /app/config/appsettings.json
              subPath: appsettings.json
            - name: basket-data-protection
              mountPath: /app/keys
          command:
            - "/bin/sh"
            - "-c"
            - "./wait-for-it.sh redis:6379 -- ./wait-for-it.sh rabbitmq:5672 -- dotnet Basket.API.dll"
          livenessProbe:
            httpGet:
              path: /health
              port: 5221
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              path: /health
              port: 5221
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 5
          resources:
            limits:
              cpu: 500m
              memory: 512Mi
            requests:
              cpu: 200m
              memory: 256Mi
      volumes:
        - name: config-volume
          configMap:
            name: release-name-config
        - name: basket-data-protection
          persistentVolumeClaim:
            claimName: basket-data-protection-pvc
---
# Source: eshop/charts/catalog/templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: release-name-catalog
  namespace: dev
  labels:
    helm.sh/chart: catalog-0.1.0
    app.kubernetes.io/name: catalog
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: catalog
      app.kubernetes.io/instance: release-name
  template:
    metadata:
      labels:
        app.kubernetes.io/name: catalog
        app.kubernetes.io/instance: release-name
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: catalog-api
          image: "docker.io/ajkabs/catalog-api:latest"
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
            - name: Database__Username
              valueFrom:
                secretKeyRef:
                  name: release-name-catalog-secret
                  key: username
            - name: Database__Password
              valueFrom:
                secretKeyRef:
                  name: release-name-catalog-secret
                  key: password
          volumeMounts:
            - name: config-volume
              mountPath: "/app/config/appsettings.json"
              subPath: appsettings.json
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
          resources:
            limits:
              cpu: 500m
              memory: 512Mi
            requests:
              cpu: 200m
              memory: 256Mi
      volumes:
        - name: config-volume
          configMap:
            name: release-name-catalog-config
---
# Source: eshop/charts/catalogdb/templates/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: release-name-catalogdb
  namespace: dev
  labels:
    
    helm.sh/chart: catalogdb-0.1.0
    app.kubernetes.io/name: catalogdb
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
spec:
  replicas: 2
  serviceName: release-name-catalogdb
  selector:
    matchLabels:
      
      app.kubernetes.io/name: catalogdb
      app.kubernetes.io/instance: release-name
  template:
    metadata:
      labels:
        
        app.kubernetes.io/name: catalogdb
        app.kubernetes.io/instance: release-name
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "5432"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: postgresql
          image: "docker.io/postgres:13"
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: release-name-catalogdb-secret
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: release-name-catalogdb-secret
                  key: password
            - name: POSTGRES_DB
              value: catalogdb
          volumeMounts:
            - name: config-volume
              mountPath: "/etc/postgresql/postgresql.conf"
              subPath: postgresql.conf
            - name: data
              mountPath: "/var/lib/postgresql/data"
          livenessProbe:
            tcpSocket:
              port: 5432
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            tcpSocket:
              port: 5432
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
          resources:
            
            limits:
              cpu: 200m
              memory: 512Mi
            requests:
              cpu: 100m
              memory: 256Mi
      volumes:
        - name: config-volume
          configMap:
            name: release-name-catalogdb-config
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes:
          
          - ReadWriteOnce
        storageClassName: standard
        resources:
          requests:
            storage: 1Gi
---
# Source: eshop/charts/rabbitmq/templates/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: release-name-rabbitmq
  namespace: dev
  labels:
    helm.sh/chart: rabbitmq-0.1.0
    app.kubernetes.io/name: rabbitmq
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
spec:
  replicas: 1
  serviceName: release-name-rabbitmq
  selector:
    matchLabels:
      app.kubernetes.io/name: rabbitmq
      app.kubernetes.io/instance: release-name
  template:
    metadata:
      labels:
        app.kubernetes.io/name: rabbitmq
        app.kubernetes.io/instance: release-name
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "5672"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: rabbitmq
          image: "docker.io/rabbitmq:3.9"
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 5672
            - containerPort: 15672
          env:
            - name: RABBITMQ_DEFAULT_USER
              valueFrom:
                secretKeyRef:
                  name: release-name-rabbitmq-secret
                  key: username
            - name: RABBITMQ_DEFAULT_PASS
              valueFrom:
                secretKeyRef:
                  name: release-name-rabbitmq-secret
                  key: password
          volumeMounts:
            - name: config-volume
              mountPath: "/etc/rabbitmq/rabbitmq.conf"
              subPath: rabbitmq.conf
            - name: data
              mountPath: "/var/lib/rabbitmq"
          livenessProbe:
            tcpSocket:
              port: 5672
            initialDelaySeconds: 60
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            tcpSocket:
              port: 5672
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
          resources:
            limits:
              cpu: 500m
              memory: 1024Mi
            requests:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: config-volume
          configMap:
            name: release-name-rabbitmq-config
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: 
          - ReadWriteOnce
        storageClassName: standard
        resources:
          requests:
            storage: 8Gi
---
# Source: eshop/charts/redis/templates/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: release-name-redis
  namespace: dev
  labels:
    helm.sh/chart: redis-0.1.0
    app.kubernetes.io/name: redis
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
spec:
  replicas: 1
  serviceName: release-name-redis
  selector:
    matchLabels:
      app.kubernetes.io/name: redis
      app.kubernetes.io/instance: release-name
  template:
    metadata:
      labels:
        app.kubernetes.io/name: redis
        app.kubernetes.io/instance: release-name
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "6379"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: redis
          image: "docker.io/redis:alpine"
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 6379
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: release-name-redis-secret
                  key: password
          volumeMounts:
            - name: config-volume
              mountPath: "/usr/local/etc/redis/redis.conf"
              subPath: redis.conf
            - name: data
              mountPath: "/data"
          livenessProbe:
            tcpSocket:
              port: 6379
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            tcpSocket:
              port: 6379
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
          resources:
            limits:
              cpu: 100m
              memory: 256Mi
            requests:
              cpu: 50m
              memory: 128Mi
      volumes:
        - name: config-volume
          configMap:
            name: release-name-redis-config
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: 
          - ReadWriteOnce
        storageClassName: standard
        resources:
          requests:
            storage: 1Gi
---
# Source: eshop/charts/basket/templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "release-name-test-connection"
  labels:
    app.kubernetes.io/name: basket-api
    app.kubernetes.io/instance: release-name
  annotations:
    "helm.sh/hook": test
spec:
  containers:
    - name: wget
      image: busybox
      command: ['wget']
      args: ['release-name:5221']
  restartPolicy: Never
---
# Source: eshop/charts/catalog/templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "release-name-catalog-test-connection"
  labels:
    helm.sh/chart: catalog-0.1.0
    app.kubernetes.io/name: catalog
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
  annotations:
    "helm.sh/hook": test
spec:
  containers:
    - name: wget
      image: busybox
      command: ['wget']
      args: ['release-name-catalog:80']
  restartPolicy: Never
---
# Source: eshop/charts/catalogdb/templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "release-name-catalogdb-test-connection"
  labels:
    helm.sh/chart: catalogdb-0.1.0
    app.kubernetes.io/name: catalogdb
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
  annotations:
    "helm.sh/hook": test
spec:
  containers:
    - name: wget
      image: busybox
      command: ['wget']
      args: ['release-name-catalogdb:5432']
  restartPolicy: Never
---
# Source: eshop/charts/rabbitmq/templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "release-name-rabbitmq-test-connection"
  labels:
    helm.sh/chart: rabbitmq-0.1.0
    app.kubernetes.io/name: rabbitmq
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
  annotations:
    "helm.sh/hook": test
spec:
  containers:
    - name: wget
      image: busybox
      command: ['wget']
      args: ['release-name-rabbitmq:5672']
  restartPolicy: Never
---
# Source: eshop/charts/redis/templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "release-name-redis-test-connection"
  labels:
    helm.sh/chart: redis-0.1.0
    app.kubernetes.io/name: redis
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
  annotations:
    "helm.sh/hook": test
spec:
  containers:
    - name: wget
      image: busybox
      command: ['wget']
      args: ['release-name-redis:6379']
  restartPolicy: Never
---
# Source: eshop/templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "release-name-eshop-test-connection"
  labels:
    helm.sh/chart: eshop-0.1.0
    app.kubernetes.io/name: eshop
    app.kubernetes.io/instance: release-name
    app.kubernetes.io/version: "1.0.0"
    app.kubernetes.io/managed-by: Helm
  annotations:
    "helm.sh/hook": test
spec:
  containers:
    - name: wget
      image: busybox
      command: ['wget']
      args: ['release-name-eshop:80']
  restartPolicy: Never
ubuntu@ip-172-31-46-154:~/eShopOnContainer/EshopOnContainer$ 
