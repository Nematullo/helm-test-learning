#!/bin/bash

echo "Начинаем структурированную установку Argo CD в кластер Kubernetes."

NAMESPACE="argocd"

# Создаем неймспейс, если он еще не существует
echo "Создаем неймспейс '$NAMESPACE', если он не существует..."
# Используем --dry-run=client -o yaml | kubectl apply -f -, это idempotентно
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
if [ $? -ne 0 ]; then
    echo "Ошибка: Не удалось создать или проверить неймспейс '$NAMESPACE'. Выходим."
    exit 1
fi
echo "Неймспейс '$NAMESPACE' готов."

# --- ШАГ 1: ЗАГРУЗКА И ПРИМЕНЕНИЕ ОФИЦИАЛЬНОГО INSTALL.YAML (для базовых ресурсов и CRD) ---
echo "Шаг 1: Загружаем и применяем официальный манифест Argo CD (включая CRD и основные компоненты)."

# Проверяем наличие wget или curl
if ! command -v wget &> /dev/null && ! command -v curl &> /dev/null; then
    echo "Ошибка: Для загрузки требуется 'wget' или 'curl'. Пожалуйста, установите один из них."
    exit 1
fi

# Скачиваем полный install.yaml для стабильной версии
OFFICIAL_INSTALL_FILE="argocd-official-install.yaml"
DOWNLOAD_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

# Скачиваем файл только если его нет или если он пустой
if [ ! -f "$OFFICIAL_INSTALL_FILE" ] || [ ! -s "$OFFICIAL_INSTALL_FILE" ]; then
    echo "Загружаем официальный install.yaml ($DOWNLOAD_URL) в файл ($OFFICIAL_INSTALL_FILE)..."
    if command -v wget &> /dev/null; then
        wget -q --show-progress "$DOWNLOAD_URL" -O "$OFFICIAL_INSTALL_FILE" || { echo "Ошибка: Не удалось загрузить $OFFICIAL_INSTALL_FILE. Проверьте подключение к интернету или URL."; exit 1; }
    elif command -v curl &> /dev/null; then
        curl -sSL "$DOWNLOAD_URL" -o "$OFFICIAL_INSTALL_FILE" || { echo "Ошибка: Не удалось загрузить $OFFICIAL_INSTALL_FILE. Проверьте подключение к интернету или URL."; exit 1; }
    fi

    # Проверка, что файл не пустой после загрузки
    if [ ! -s "$OFFICIAL_INSTALL_FILE" ]; then
        echo "Ошибка: Загруженный файл ($OFFICIAL_INSTALL_FILE) пуст или недействителен."
        exit 1
    fi
    echo "Официальный install.yaml успешно загружен."
else
    echo "Файл $OFFICIAL_INSTALL_FILE уже существует и не пуст. Используем существующую версию."
fi


# Применяем весь официальный манифест.
# Это создаст дефолтные Deployment'ы, Service'ы, ConfigMaps, Secrets, включая Argo CD Server (Deployment).
kubectl apply -f "$OFFICIAL_INSTALL_FILE" -n "$NAMESPACE" || { echo "Ошибка: Не удалось применить $OFFICIAL_INSTALL_FILE. Выходим."; exit 1; }
echo "Основные компоненты Argo CD из official install.yaml успешно применены."
sleep 5 # Короткая пауза перед применением кастомных файлов

# --- ШАГ 2: ВЫБОР ТИПА РАЗВЕРТЫВАНИЯ ARGO CD SERVER ---
ARGO_SERVER_DEPLOY_FILE=""
ARGO_SERVER_RESOURCE_TYPE="" # Для использования в wait_for_resource

while true; do
    echo ""
    echo "Как вы хотите развернуть Argo CD Server?"
    echo "1) StatefulSet (Постоянное имя пода: argocd-server-0)"
    echo "2) Deployment (Случайное имя пода: argocd-server-xxxxxxx, по умолчанию)"
    read -p "Введите 1 или 2: " choice

    case $choice in
        1)
            # Если выбран StatefulSet
            if [ -f "argocd-server-statefullset.yaml" ]; then
                # Удаляем дефолтный Deployment, чтобы избежать конфликтов
                echo "Удаляем дефолтный Deployment argocd-server для установки StatefulSet..."
                kubectl delete deployment argocd-server -n "$NAMESPACE" --ignore-not-found=true --wait=true
                
                ARGO_SERVER_DEPLOY_FILE="argocd-server-statefullset.yaml"
                ARGO_SERVER_RESOURCE_TYPE="StatefulSet"
                echo "Выбран StatefulSet. Будет использован 'argocd-server-statefullset.yaml'."
                break
            else
                echo "Ошибка: Файл 'argocd-server-statefullset.yaml' не найден. Пожалуйста, создайте его или выберите Deployment."
            fi
            ;;
        2)
            # Если выбран Deployment
            # Удаляем StatefulSet, если он вдруг был создан ранее (чтобы убедиться, что используется Deployment)
            echo "Удаляем StatefulSet argocd-server, если он существует, для использования Deployment..."
            kubectl delete statefulset argocd-server -n "$NAMESPACE" --ignore-not-found=true --wait=true
            
            ARGO_SERVER_DEPLOY_FILE="$OFFICIAL_INSTALL_FILE" # Будем полагаться на дефолтный Deployment
            ARGO_SERVER_RESOURCE_TYPE="Deployment"
            echo "Выбран Deployment. Будет использован дефолтный Deployment из official install.yaml."
            break
            ;;
        *)
            echo "Неверный ввод. Пожалуйста, введите 1 или 2."
            ;;
    esac
done

# Применяем выбранный ресурс для argocd-server
# Если выбран StatefulSet, применяем argocd-server-statefullset.yaml
# Если выбран Deployment, мы уже применили его с official install.yaml, но если нужно переприменить, можно сделать это здесь.
# Однако, лучше просто дождаться, если это Deployment.
if [ "$ARGO_SERVER_RESOURCE_TYPE" == "StatefulSet" ]; then
    echo "Применяем выбранный Argo CD Server ($ARGO_SERVER_RESOURCE_TYPE) из $ARGO_SERVER_DEPLOY_FILE..."
    # Используем --overwrite=true, чтобы гарантировать применение ваших изменений
    kubectl apply -f "$ARGO_SERVER_DEPLOY_FILE" -n "$NAMESPACE" --overwrite=true || { echo "Ошибка: Не удалось применить $ARGO_SERVER_RESOURCE_TYPE для Argo CD Server. Выходим."; exit 1; }
    echo "Применен $ARGO_SERVER_RESOURCE_TYPE для Argo CD Server."
fi


# --- ШАГ 3: ПРИМЕНЕНИЕ ВАШИХ КАСТОМНЫХ НАСТРОЕК ---
echo "Шаг 3: Применяем ваши кастомные настройки для Argo CD (NodePorts, RBAC, Keycloak/OIDC, Admin Password)."

declare -a CUSTOM_CONFIG_FILES=(
    "argocd-server-service.yaml"      # Ваш сервис с NodePort для Argo CD Server
    "argocd-repo-server-service.yaml" # Ваш сервис Repo Server (ClusterIP)
    "argocd-dex-service.yaml"         # Ваш сервис Dex (ClusterIP)
    "argocd-rbac-cm.yaml"             # Ваш ConfigMap с RBAC политиками
    "argocd-cm.yaml"                  # Ваш ConfigMap для OIDC и URL (или keycloack-argocd-app-cm.yaml)
    "argocd-admin-secret.yaml"        # Ваш Secret с паролем администратора
    "argocd-ssh-known-hosts-cm.yaml" # Ваша ConfigMap для SSH Known Hosts
)

for file in "${CUSTOM_CONFIG_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "Применяем кастомный файл: $file"
        # Используем --overwrite=true, чтобы гарантировать применение ваших изменений
        # Проверяем на пустой файл перед применением
        if [ -s "$file" ]; then
            kubectl apply -f "$file" -n "$NAMESPACE" --overwrite=true || { echo "Предупреждение: Произошла ошибка при применении файла $file. Проверьте его синтаксис и содержимое."; }
        else
            echo "Предупреждение: Кастомный файл $file найден, но пуст. Пропускаем применение."
        fi
    else
        echo "Предупреждение: Кастомный файл $file не найден. Пропускаем применение."
    fi
done

echo ""
echo "Кастомные настройки применены."

# --- ДИНАМИЧЕСКОЕ ОЖИДАНИЕ ГОТОВНОСТИ ПОДОВ ---
echo "Ожидаем готовности основных компонентов Argo CD..."

# Функция для ожидания ресурса (Deployment или StatefulSet)
wait_for_resource() {
    local resource_type="$1"
    local resource_name="$2"
    echo "Ожидаем $resource_type/$resource_name в неймспейсе '$NAMESPACE'..."
    # Таймаут увеличен до 600 секунд, так как minikube может быть медленным
    kubectl wait --for=condition=ready "$resource_type"/"$resource_name" -n "$NAMESPACE" --timeout=600s
    if [ $? -ne 0 ]; then
        echo "Ошибка: Таймаут ожидания запуска $resource_type/$resource_name."
        # Дополнительная отладка: покажем логи подов, которые не готовы
        echo "Логи подов, которые не готовы:"
        kubectl get pods -n "$NAMESPACE" -o wide | grep "ContainerCreating\|Init:0/1\|CrashLoopBackOff\|Error"
        for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' --field-selector=status.phase!=Running,status.phase!=Succeeded); do
            echo "--- Логи для пода: $pod ---"
            kubectl logs "$pod" -n "$NAMESPACE" --all-containers=true
            echo "--- Описание для пода: $pod ---"
            kubectl describe pod "$pod" -n "$NAMESPACE"
        done
        return 1
    fi
    return 0
}

# Ожидаем готовности каждого основного компонента
# Обратите внимание: argocd-server будет ждать либо Deployment, либо StatefulSet, в зависимости от выбора.
# argocd-application-controller теперь ждем как StatefulSet
wait_for_resource "$ARGO_SERVER_RESOURCE_TYPE" "argocd-server" || { echo "Ошибка: Argo CD Server не готов. Проверьте логи."; exit 1; }
wait_for_resource "StatefulSet" "argocd-application-controller" || { echo "Ошибка: Argo CD Application Controller не готов. Проверьте логи."; exit 1; }
wait_for_resource "Deployment" "argocd-repo-server" || { echo "Ошибка: Argo CD Repo Server не готов. Проверьте логи."; exit 1; }
wait_for_resource "Deployment" "argocd-dex-server" || { echo "Ошибка: Argo CD Dex Server не готов. Проверьте логи."; exit 1; }
wait_for_resource "Deployment" "argocd-redis" || { echo "Ошибка: Argo CD Redis не готов. Проверьте логи."; exit 1; }
wait_for_resource "Deployment" "argocd-applicationset-controller" || { echo "Ошибка: Argo CD ApplicationSet Controller не готов. Проверьте логи."; exit 1; }
wait_for_resource "Deployment" "argocd-notifications-controller" || { echo "Ошибка: Argo CD Notifications Controller не готов. Проверьте логи."; exit 1; }


echo "Поды Argo CD готовы. Проверка статуса:"
kubectl get pods -n "$NAMESPACE"

echo ""
echo "Получение начального пароля администратора Argo CD:"
# Проверяем наличие секрета и извлекаем пароль
if kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret &>/dev/null; then
    ADMIN_PASSWORD=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    echo "Имя пользователя: admin"
    echo "Пароль: $ADMIN_PASSWORD"
else
    # Если default-секрет не найден, пытаемся получить пароль из argocd-secret, если он был задан
    if kubectl -n "$NAMESPACE" get secret argocd-secret -o jsonpath="{.data.admin\.password}" &>/dev/null; then
        ADMIN_PASSWORD=$(kubectl -n "$NAMESPACE" get secret argocd-secret -o jsonpath="{.data.admin\.password}" | base64 -d)
        echo "Имя пользователя: admin"
        echo "Пароль: $ADMIN_PASSWORD (установлен из argocd-admin-secret.yaml)"
    else
        echo "Ошибка: Начальный секрет 'argocd-initial-admin-secret' или 'argocd-secret' не найден."
        echo "Возможно, Argo CD Server не инициализировался корректно или секрет не был применен."
        echo "Вы можете сбросить пароль вручную с помощью 'argocd account update --password <YOUR_PASSWORD> --current-password-is-empty'"
    fi
fi

echo ""
echo "Argo CD UI будет доступен по адресу: http://<IP_вашего_узла_Kubernetes>:30080 (HTTP) или https://<IP_вашего_узла_Kubernetes>:30443 (HTTPS)"
echo "Не забудьте настроить 'Valid Redirect URIs' в Keycloak: https://<IP_вашего_узла_Kubernetes>:30443/api/v1/session/callback"
echo "Убедитесь, что 'url' в 'argocd-cm.yaml' (или 'keycloack-argocd-app-cm.yaml') корректно настроен с вашим IP-адресом."

echo "---"
echo "Установка Argo CD и применение всех ресурсов завершены."
echo "Проверьте логи подов и состояние ресурсов, если возникли проблемы."