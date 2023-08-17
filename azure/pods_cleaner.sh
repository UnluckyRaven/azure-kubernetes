#!/bin/bash

WEBHOOK="" # Indicar el Webhook
ERRORES=""
PODS_WAITING=""

help_panel() {
    # Panel de ayuda
	echo -e "\n[*] Uso: ./pods_management.sh -s {ID_Subscripcion} -r {Resource_Group} -n {Nombre_AKS}"
	exit 0
}

exit_status() {
    # Comprueba que no haya habido errores a lo largo de la ejecucion
    if [[ -n $ERRORES ]]; then
        exit 1
	fi
    exit 0
}

resume() {
    # ! elegir entre el curl y el echo
    # Notifica a traves del webhook a teams. Notifica lo siguiente:
    #   Errores a lo largo de la ejecucion
    #   Pods que estaban en Evicted
    #   Pods que estaban Running pero alguno de sus contenedores estaba en Waiting

    # Enviarlo mediante un webhook
    curl -H "Content-Type: application/json" -d "{'title':'Pods EVICTED del AKS $NAME_AKS','text':'[+] Errores enontrados:<br>${ERRORES}<br>[+] Los siguientes pods estaban en estado <strong>\"EVICTED\"</strong>:<br>$(echo "$PODS_EVICTED" | sed ':a;N;$!ba;s/\n/<br>/g')<br>[+] Los siguientes pods estaban <strong>\"Running\"</strong> con algun contenedor con el estado <strong>\"Waiting\"</strong>:<br>${PODS_WAITING}'}" $WEBHOOK
    # Imprimirlo por pantalla
    echo -e "\n[+] Errores enontrados:\n$ERRORES\n[+] Los siguientes pods estaban en estado \"EVICTED\":\n$PODS_EVICTED\n\n[+] Los siguientes pods estaban \"Running\" con algun contenedor con el estado \"Waiting\":\n$PODS_WAITING"
    return 0
}

connect_aks() {
    # Conectamos al aks
    if [[ -n $VERVOSITY ]]; then
        echo -e "[/] Connecting to $NAME_AKS ..."
    fi
    az account set --subscription "$ID_SUB" || return 1
    az aks get-credentials --resource-group "$RG" --name "$NAME_AKS" --admin --overwrite-existing || return 1
    return 0
}

check_connect() {
    # Comprueba que estas en la subscripcion correcta
    ACC=$(az account show | grep "$ID_SUB" | awk -F ":" '{print $2}' | cut -d "\"" -f 2)
    if [[ "$ACC" != "$ID_SUB" ]]; then
        return 1
    fi
    return 0
}

waiting_status() {
	# itera por cada contenedor del pod, si alguno esta en estado "waiting" devuelve 0, si no, 1. Por lo que con [if ! waiting_status;] se puede comprobar  
	CONT_STATUS=$(echo "$FILTER" | grep "$1" | awk -F ";" '{print $6}') # devuelve los estados de cada contenedor del pod
	for i in ${CONT_STATUS}; do
		if [[ "$i" == *waiting* ]]; then
			return 0
		fi
	done
	return 1
}

max_restart() {
    # itera por cada contenedor del pod
	RESTARTS=$(echo "$FILTER" | grep "$1" | awk -F ";" '{print $5}')
	MAX=0
	for i in ${RESTARTS}; do
		if [[ $MAX -lt $i ]]; then
			MAX=$i
		fi
	done
}

filter_evicted(){
    # Filtramos por los pods que esten en estado EVICTED
    if [[ -n $VERVOSITY ]]; then
        echo -e "\n[/] Looking for pods in Evicted state ...\n"
    fi
    PODS_EVICTED=$(echo "$FILTER" | grep Evicted | awk -F ";" '{print $1}')
    
    # Iteramos por cada pod, eliminandolo y en caso de fallar, notifica.
    for pod in ${PODS_EVICTED}; do
        NAMESPACE=$(echo -e "$FILTER" | grep "$pod" | awk -F ";" '{print $4}')
        if [[ -n $VERVOSITY ]]; then
            echo -e "[-] Deleting pod \"$pod\" ..."
        fi
        MOTIVO=$(kubectl delete pod -n "$NAMESPACE" "$pod" 2>&1)
        if [ "$?" != 0 ]; then
            ERRORES+="[Evicted] ${pod} -> ${MOTIVO} \n"
            if [[ -n $VERVOSITY ]]; then
                echo -e "\t|_ Pod deleting failed: ${MOTIVO} \n"
            fi
        fi
    done

    return 0
}

filter_error(){
    # borrar los pods que esten running pero tengan algun warning tras haber reiniciado 5 veces
    if [[ -n $VERVOSITY ]]; then
        echo -e "\n[/] Looking for pods with warnings ...\n"
    fi
    PODS=$(echo "$FILTER" | grep Running | awk -F ";" '{print $1}')
    
	for pod in $PODS; do
		max_restart "$pod"
        # ? con 5 reinicios suficiente?
		if [[ "$MAX" -gt 5 ]] && waiting_status "$pod"; then
            PODS_WAITING+="$pod\n"
            if [[ -n $VERVOSITY ]]; then
                echo -e "[-] Deleting pod \"$pod\" ..."	
            fi
            NAMESPACE=$(echo -e "$FILTER" | grep "$pod" | awk -F ";" '{print $4}')
            MOTIVO=$(kubectl delete pod -n "$NAMESPACE" "$pod" 2>&1)
            if [ "$?" != 0 ]; then
                ERRORES+="[Warning] ${pod} -> ${MOTIVO} \n"
                if [[ -n $VERVOSITY ]]; then
                    echo -e "\t|_ Pod deleting failed: ${MOTIVO} \n"
                fi
            fi
		fi
	done

    return 0
}

##########################
##  Programa principal  ##
##########################

while getopts "hs:r:n:v" opt; do
    case "${opt}" in
          s) ID_SUB=${OPTARG} ;;
          r) RG=${OPTARG} ;;
          n) NAME_AKS=${OPTARG} ;;
		      v) VERVOSITY=1 ;;
          h | *) help_panel ;;
     esac
done

if [[ -n $ID_SUB ]] && [[ -n $RG ]] && [[ -n $NAME_AKS ]]; then
    if ! connect_aks; then
        echo -e "FAILED! Couldn't connect to $NAME_AKS."
        exit 1
    fi
    if check_connect; then
        # El filtro recoge la siguiemte informacion de cada pod:
        #	$1 - pod name
        #	$2 - estado del pod (Running, pendind, failed)
        #	$3 - en caso del estado failed, si esta en Evicted
        #	$4 - namespace
        #	$5 - los reinicios de cada contendor del pod
        #	$6 - el estado de cada contenedor del pod
        FILTER=$(kubectl get pods -A -o=jsonpath="{range .items[*]}{.metadata.name}{';'}{.status.phase}{';'}{.status.reason}{';'}{.metadata.namespace}{';'}{.status.containerStatuses[*].restartCount}{';'}{.status.containerStatuses[*].state}{'\n'}{end}")

        # eliminamos los pods en evicted
        filter_evicted

        # esperamos 1 minuto para que los nuevos pods se redesplieguen
        sleep 60s
        
        # Sacamos los nuevos estados de los pods
        FILTER=$(kubectl get pods -A -o=jsonpath="{range .items[*]}{.metadata.name}{';'}{.status.phase}{';'}{.status.reason}{';'}{.metadata.namespace}{';'}{.status.containerStatuses[*].restartCount}{';'}{.status.containerStatuses[*].state}{'\n'}{end}")

        # elimina los pods que estan en running con algun contenedor en waiting tras mas de 5 reinicios
        filter_error    
    
    fi
   
    resume
    exit_status

else
    help_panel
fi
