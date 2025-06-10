#!/bin/bash

echo "Начинаем структурированную установку Argo CD в кластер Kubernetes."

NAMESPACE="argocd"

# Создаем неймспейс, если он еще не существует
echo "Создаем неймспейс '$NAMESPACE', если он не существует..."
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

echo "Загружаем официальный install.yaml ($DOWNLOAD_URL) в файл ($OFFICIAL_INSTALL_FILE)..."
if command -v wget &> /dev/null; then
    wget -q --show-progress "$DOWNLOAD_URL" -O "$OFFICIAL_INSTALL_FILE" || { echo "Ошибка: Не удалось загрузить $OFFICIAL_INSTALL_FILE. Проверьте подключение к интернету или URL."; exit 1; }
elif command -v curl &> /dev/null; then
    curl -sSL "$DOWNLOAD_URL" -o "$OFFICIAL_INSTALL_FILE" || { echo "Ошибка: Не удалось загрузить $OFFICIAL_INSTALL_FILE. Проверьте подключение к интернету или URL."; exit 1; }
fi

# Проверка, что файл не пустой
if [ ! -s "$OFFICIAL_INSTALL_FILE" ]; then
    echo "Ошибка: Загруженный файл ($OFFICIAL_INSTALL_FILE) пуст или недействителен."
    exit 1
fi

echo "Официальный install.yaml успешно загружен."

# Применяем весь официальный манифест.
# Это создаст дефолтные Deployment'ы, Service'ы, ConfigMaps, Secrets, включая Argo CD Server (Deployment).
kubectl apply -f "$OFFICIAL_INSTALL_FILE" -n "$NAMESPACE" || { echo "Ошибка: Не удалось применить $OFFICIAL_INSTALL_FILE. Выходим."; exit 1; }
echo "Основные компоненты Argo CD из official install.yaml успешно применены."
sleep 5 # Короткая пауза перед применением кастомных файлов

# --- ШАГ 2: ВЫБОР ТИПА РАЗВЕРТЫВАНИЯ ARGO CD SERVER ---
ARGO_SERVER_DEPLOY_FILE=""
ARGO_SERVER_RESOURCE_TYPE=""

# Добавим временный манифест для выбранного типа развертывания,
# чтобы гарантировать, что он будет применен ПОВЕРХ дефолтного из official install.yaml.
# Имя ресурса 'argocd-server' должно совпадать.
TEMP_SERVER_OVERLAY_FILE="argocd-server-overlay.yaml"

while true; do
    echo ""
    echo "Как вы хотите развернуть Argo CD Server?"
    echo "1) StatefulSet (Постоянное имя пода: argocd-server-0)"
    echo "2) Deployment (Случайное имя пода: argocd-server-xxxxxxx, по умолчанию)"
    read -p "Введите 1 или 2: " choice

    case $choice in
        1)
            # Если выбран StatefulSet, используем ваш файл для StatefulSet
            if [ -f "argocd-server-statefullset.yaml" ]; then
                cp argocd-server-statefullset.yaml "$TEMP_SERVER_OVERLAY_FILE"
                ARGO_SERVER_RESOURCE_TYPE="StatefulSet"
                echo "Выбран StatefulSet. Будет использован 'argocd-server-statefullset.yaml'."
                break
            else
                echo "Ошибка: Файл 'argocd-server-statefullset.yaml' не найден. Пожалуйста, создайте его или выберите Deployment."
            fi
            ;;
        2)
            # Если выбран Deployment, мы по сути переприменяем дефолтный Deployment
            # или можем просто оставить его как есть (он уже применен из install.yaml).
            # Чтобы явно "выбрать" его, мы можем создать пустой файл-заглушку
            # или использовать логику, которая просто не переопределяет его.
            # Для ясности, я сделаю, что мы "удаляем" StatefulSet, если он вдруг был создан,
            # и явно подтверждаем, что Deployment используется.
            echo "Выбран Deployment. Будет использован дефолтный Deployment из install.yaml."
            ARGO_SERVER_RESOURCE_TYPE="Deployment"
            # Удаляем временный файл, если он существовал от предыдущих попыток
            rm -f "$TEMP_SERVER_OVERLAY_FILE"
            break
            ;;
        *)
            echo "Неверный ввод. Пожалуйста, введите 1 или 2."
            ;;
    esac
done

# Если выбран StatefulSet, применяем его, чтобы переопределить дефолтный Deployment
if [ -f "$TEMP_SERVER_OVERLAY_FILE" ]; then
    echo "Применяем выбранный Argo CD Server ($ARGO_SERVER_RESOURCE_TYPE) из $TEMP_SERVER_OVERLAY_FILE..."
    kubectl apply -f "$TEMP_SERVER_OVERLAY_FILE" -n "$NAMESPACE" --overwrite=true || { echo "Ошибка: Не удалось применить $ARGO_SERVER_RESOURCE_TYPE для Argo CD Server. Выходим."; exit 1; }
    echo "Применен $ARGO_SERVER_RESOURCE_TYPE для Argo CD Server."
    rm -f "$TEMP_SERVER_OVERLAY_FILE" # Очистка временного файла
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
)

for file in "${CUSTOM_CONFIG_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "Применяем кастомный файл: $file"
        # Используем --overwrite=true, чтобы гарантировать применение ваших изменений
        kubectl apply -f "$file" -n "$NAMESPACE" --overwrite=true || { echo "Предупреждение: Произошла ошибка при применении файла $file. Возможно, это нормально для дополнительных ресурсов."; }
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
    kubectl wait --for=condition=ready "$resource_type"/"$resource_name" -n "$NAMESPACE" --timeout=300s
    if [ $? -ne 0 ]; then
        echo "Ошибка: Таймаут ожидания запуска $resource_type/$resource_name."
        # Дополнительная отладка: покажем логи подов, которые не готовы
        echo "Логи подов, которые не готовы:"
        kubectl get pods -n "$NAMESPACE" -o wide | grep "ContainerCreating\|Init:0/1"
        for pod in $(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' --field-selector=status.phase!=Running,status.phase!=Succeeded); do
            echo "--- Logs for pod: $pod ---"
            kubectl logs "$pod" -n "$NAMESPACE" --all-containers=true
            echo "--- Describe for pod: $pod ---"
            kubectl describe pod "$pod" -n "$NAMESPACE"
        done
        return 1
    fi
    return 0
}

# Ожидаем готовности каждого основного компонента
# Обратите внимание: argocd-server будет ждать либо Deployment, либо StatefulSet, в зависимости от выбора.
wait_for_resource "$ARGO_SERVER_RESOURCE_TYPE" "argocd-server" || { echo "Ошибка: Argo CD Server не готов. Проверьте логи."; exit 1; }
wait_for_resource "Deployment" "argocd-application-controller" || { echo "Ошибка: Argo CD Application Controller не готов. Проверьте логи."; exit 1; }
wait_for_resource "Deployment" "argocd-repo-server" || { echo "Ошибка: Argo CD Repo Server не готов. Проверьте логи."; exit 1; }
wait_for_resource "Deployment" "argocd-dex-server" || { echo "Ошибка: Argo CD Dex Server не готов. Проверьте логи."; exit 1; }
wait_for_resource "Deployment" "argocd-redis" || { echo "Ошибка: Argo CD Redis не готов. Проверьте логи."; exit 1; } # Добавлено ожидание Redis
wait_for_resource "Deployment" "argocd-applicationset-controller" || { echo "Ошибка: Argo CD ApplicationSet Controller не готов. Проверьте логи."; exit 1; } # Добавлено ожидание ApplicationSet Controller
wait_for_resource "Deployment" "argocd-notifications-controller" || { echo "Ошибка: Argo CD Notifications Controller не готов. Проверьте логи."; exit 1; } # Добавлено ожидание Notifications Controller


echo "Поды Argo CD готовы. Проверка статуса:"
kubectl get pods -n "$NAMESPACE"

echo ""
echo "Получение начального пароля администратора Argo CD:"
if kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret &>/dev/null; then
    ADMIN_PASSWORD=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
    echo "Имя пользователя: admin"
    echo "Пароль: $ADMIN_PASSWORD"
else
    echo "Ошибка: Секрет 'argocd-initial-admin-secret' не найден. Возможно, Argo CD Server не инициализировался корректно."
    echo "Если вы задавали пароль через 'argocd-admin-secret.yaml', то он уже должен быть установлен."
    echo "Вы можете также установить пароль вручную с помощью 'argocd account update --password <YOUR_PASSWORD>'"
fi

echo ""
echo "Argo CD UI будет доступен по адресу: http://<IP_вашего_узла_Kubernetes>:30080 (HTTP) или https://<IP_вашего_узла_Kubernetes>:30443 (HTTPS)"
echo "Не забудьте настроить 'Valid Redirect URIs' в Keycloak: https://<IP_вашего_узла_Kubernetes>:30443/api/v1/session/callback"
echo "Убедитесь, что 'url' в 'argocd-cm.yaml' (или 'keycloack-argocd-app-cm.yaml') корректно настроен с вашим IP-адресом."

echo "---"
echo "Установка Argo CD и применение всех ресурсов завершены."
echo "Проверьте логи подов и состояние ресурсов, если возникли проблемы."