#!/bin/bash

# Este script itera sobre cada cosmos y contenedores, migrando a autoscale aquellas que estan en manual y fijando al minimo posible sus RU/s para evitar cualquier error humano de olvidarse una cosmos a otro valor y ahorrar costes.

# Definición de variables.
COSMOS_ACCOUNT=$1
RG_NAME=$2
sp_ID=$3

DATE=$(date +%d/%m/%Y-%H:%M:%S)     # fecha decuando se ejecuta el script
FILE_PATH="/root/cosmos_data"       # ruta para guardar los logs
OUTPUT_OK=""                        # variable donde se guardan las cosmos que no se han modificado
OUTPUT_MODIFIED=""                  # variable donde se guardan las cosmos que si se han modificado
OUTPUT_BAD=""                       # variable donde se guardan los errores encontrados
WEBHOOK="https://everisgroup.webhook.office.com/webhookb2/7d3d479a-d119-476a-b4b7-36979e25db41@3048dc87-43f0-4100-9acb-ae1971c79395/IncomingWebhook/8bea29b52d56479c8c27adc2f95cf2a5/5d4966a5-15a3-4f89-8bea-99bd0ea5e895"

help_panel() {
    # Panel de ayuda
        echo -e "\n[*] Uso: $0 {Cosmos_Account} {Resource_Group} {ID_Subscripcion}"
        exit 0
}

write_localy(){
    echo -e "$TMP_DB" >> ${FILE_PATH}/cosmosdb_data
    echo -e "$TMP_CONTAINER" >> ${FILE_PATH}/container_data
    return 0
}

notify() {
    # Notifica con las cosmos que se hayan modificado con exito y las que haya fallado, si falla el envío de la notificacion guardará los logs en local
    curl -H "Content-Type: application/json" -d "{'title':'Bajada RU/s de ${COSMOS_ACCOUNT} [${sp_ID}] - ${DATE}','text':'Las siguientes cosmosdb han modificado sus RU/s:<br>${OUTPUT_MODIFIED}<br><br>Errores Encontrados:<br>${OUTPUT_BAD}<br><br>Las siguientes cosmos se mantienen como estaban:<br>${OUTPUT_OK}'}" "$WEBHOOK"
    return
}

error_msg() {
    if [[ "$1" == "db" ]]; then
        OUTPUT_BAD+="[-] $COSMOS_ACCOUNT <strong>$db</strong>. ERROR: No se pudo cambiar el throughput. Se mantiene en <strong>$DB_THROUGHPUT</strong>. <br>"
    else
        OUTPUT_BAD+="[-] $COSMOS_ACCOUNT $db <strong>$container</strong>. ERROR: No se pudo cambiar el throughput. Se mantiene en <strong>$CONTAINER_THROUGHPUT</strong>. <br>"
    fi
}

bucle() {
    # sacamos el valor minimo que acepta la cosmos/coleccion y establecemos ese valor
    if [[ "$1" == "db" ]]; then
        MIN_VAL_DB=$(az cosmosdb sql database throughput show -a "$COSMOS_ACCOUNT" -g "$RG_NAME" --subscription "$sp_ID" -n "$db" --query resource.minimumThroughput -o tsv)
        if (( DB_THROUGHPUT != MIN_VAL_DB )); then
            if ! az cosmosdb sql database throughput update -a "$COSMOS_ACCOUNT" -g "$RG_NAME" --subscription "$sp_ID" -n "$db" --max-throughput "$MIN_VAL_DB" 2> /dev/null; then
                error_msg "db"
            else
                OUTPUT_MODIFIED+="[+] <strong>$db</strong> cambiado de <strong>$DB_THROUGHPUT</strong> a <strong>$MIN_VAL_DB</strong> RU/s. <br>"
            fi

        else
            OUTPUT_OK+="[+] <strong>$db</strong> se mantiene a <strong>$DB_THROUGHPUT</strong> RU/s. <br>"
        fi

    elif [[ "$1" == "container" ]]; then
        MIN_VAL_CONT=$(az cosmosdb sql container throughput show -a "$COSMOS_ACCOUNT" -g "$RG_NAME" --subscription "$sp_ID" -d "$db" -n "$container" --query resource.minimumThroughput -o tsv)
        if (( CONTAINER_THROUGHPUT != MIN_VAL_CONT )); then
            if ! az cosmosdb sql container throughput update -a "$COSMOS_ACCOUNT" -g "$RG_NAME" --subscription "$sp_ID" -d "$db" -n "$container" --max-throughput "$MIN_VAL_CONT" 2> /dev/null; then
                error_msg "container"
            else
                OUTPUT_MODIFIED+="[+] $db <strong>$container</strong> cambiado de <strong>$CONTAINER_THROUGHPUT</strong> a <strong>$2</strong> Ru/s. <br>"
            fi

        else
            OUTPUT_OK+="[+] $db <strong>$container</strong> se mantiene a <strong>$CONTAINER_THROUGHPUT</strong> Ru/s. <br>"
        fi
    else
        return 0
    fi
}


principal() {
    # Obtenemos listado de BBDD.
    COSMOS_DB=$(az cosmosdb sql database list -a "${COSMOS_ACCOUNT}" -g "${RG_NAME}" --subscription "${sp_ID}" --query [].name -o tsv)

    # Se tratan cada BBDD y sus respectivos contenedores.
    for db in ${COSMOS_DB}; do
        # obtenemos las RU/s que tiene en un inicio para  guardarlo como log
        DB_THROUGHPUT=$(az cosmosdb sql database throughput show -a "${COSMOS_ACCOUNT}" -n "${db}" -g "${RG_NAME}" --subscription "${sp_ID}" --query resource.autoscaleSettings.maxThroughput -o tsv 2>&1 | head -n 1 | awk '{print $1}')
        # Identificamos la configuración de las cosmos, Manual o Autoescalado.
        if [ "${DB_THROUGHPUT}" == "ERROR:"  ]; then
            DB_TYPE="NTP"
            DB_THROUGHPUT="0"
        elif [ -z "${DB_THROUGHPUT}" ]; then
        # las que sean manual, migramos a autoscale y fijamos en 100 - 1000 RU/s
            DB_TYPE="Manual"
            DB_THROUGHPUT=$(az cosmosdb sql database throughput show -a "${COSMOS_ACCOUNT}" -n "${db}" -g "${RG_NAME}" --subscription "${sp_ID}" --query resource.throughput -o tsv 2>&1 | head -n 1 | awk '{print $1}')
            az cosmosdb sql database throughput migrate -a "${COSMOS_ACCOUNT}" -g "${RG_NAME}" --subscription "${sp_ID}" -n "${db}" -t 'autoscale'
            bucle db
        elif [ "${DB_THROUGHPUT}" -gt 0 ]; then
        # fijamos en 100 - 1000 RU/s
            DB_TYPE="Auto"
            bucle db
        fi
        # Se almacena la información de la BBDD en una variable temporal por si falla al mandarlo al webhook.
        #echo "$DATE $COSMOS_ACCOUNT $db $DB_TYPE $DB_THROUGHPUT $RG_NAME $sp_ID" >> ${FILE_PATH}/cosmosdb_data
        TMP_DB+="$DATE $COSMOS_ACCOUNT $db $DB_TYPE $DB_THROUGHPUT $RG_NAME $sp_ID\n"

        # Obtenemos todos los contendores de las BBDD.
        CONTAINERS=$(az cosmosdb sql container list -a "${COSMOS_ACCOUNT}" -d "${db}" -g "${RG_NAME}" --subscription "${sp_ID}" --query [].name -o tsv)
        for container in ${CONTAINERS}; do
            CONTAINER_THROUGHPUT=$(az cosmosdb sql container throughput show -a "${COSMOS_ACCOUNT}" -d "${db}" -g "${RG_NAME}" --subscription "${sp_ID}" -n "${container}" --query resource.autoscaleSettings.maxThroughput -o tsv 2>&1 | head -n 1 | awk '{print $1}')
            # Identificamos la configuración de los contenedores, Manual o Autoescalado.
            if [ "${CONTAINER_THROUGHPUT}" == "ERROR:"  ]; then
                CONTAINER_TYPE="NTPC"
                CONTAINER_THROUGHPUT="0"
            elif [ -z "${CONTAINER_THROUGHPUT}" ]; then
            # las que sean manual, migramos a autoscale y fijamos en 100 - 1000 RU/s
                CONTAINER_TYPE="Manual"
                CONTAINER_THROUGHPUT=$(az cosmosdb sql container throughput show -a "${COSMOS_ACCOUNT}" -d ${db} -g "${RG_NAME}" --subscription "${sp_ID}" -n "${container}" --query resource.throughput -o tsv)
                az cosmosdb sql container throughput migrate -a "${COSMOS_ACCOUNT}" -g "${RG_NAME}" --subscription "${sp_ID}" -d "${db}" -n "${container}" -t 'autoscale'
                bucle container
            elif [ "${CONTAINER_THROUGHPUT}" -gt 0 ]; then
                CONTAINER_TYPE="Auto"
                bucle container
            fi
            # Se almacena la información del contenedor en una variable temporal por si falla al mandarlo al webhook.
            #echo "$DATE $COSMOS_ACCOUNT $db $container $CONTAINER_TYPE $CONTAINER_THROUGHPUT $RG_NAME $sp_ID" >> ${FILE_PATH}/container_data
            TMP_CONTAINER+="$DATE $COSMOS_ACCOUNT $db $container $CONTAINER_TYPE $CONTAINER_THROUGHPUT $RG_NAME $sp_ID\n"
        done

    done
}

# Comprobamos si tiene 3 argumentos
if [ "$1" == '-h' ] || [ "$1" == '--help' ]; then
    help_panel
elif [ $# -ne 3 ]; then
    #help_panel
    echo "No se ha podido ejecutar el script. [*] Uso: $0 {Cosmos_Account} {Resource_Group} {ID_Subscripcion}"
    exit 1
else
    principal
    notify
    ret=$?
    # Si no puede mandarlo al webhook de teams, guardará en local los logs
    if [[ $ret != 0 ]]; then
        write_localy
    fi

    # Si se ha encontrado con algun error, marcar el script como fallido.
    if [[ -n $OUTPUT_BAD ]]; then
        exit 1
    fi
    exit 0
fi
