#!/bin/bash

connect_aks() {
    # Conectamos al aks
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

increment_25p(){
    return $(($1*125/100))
}

set_max_replicas(){
    # sacamos el valor actual de maxReplicas
    max=$(kubectl get hpa -n "$NAMESPACE" "$HPA" -o=yaml | grep maxReplicas: | awk -F " " '{print $2}')

    # calculamos el 125% (para aumentar el máximo en un 25%)
    if [ -n "$max" ]; then
        increment_25p "$max"
        new_max=$?
    fi

    if [ -n "$new_max" ]; then
        echo "Cambiando maxReplicas a $new_max ..."
        kubectl patch hpa my-hpa -p '{"spec":{"maxReplicas":$new_max}}'
    fi
}

##########################
##  Programa principal  ##
##########################

while getopts "h:n:a:g:s:" opt; do
    case "${opt}" in
          h) HPA=${OPTARG} ;;
          n) NAMESPACE=${OPTARG} ;;
          a) NAME_AKS=${OPTARG} ;;
          g) RG=${OPTARG} ;;
          s) ID_SUB=${OPTARG} ;;
          *) ;;
     esac
done

if [ -n "$HPA" ] && [ -n "$NAMESPACE" ] && [ -n "$NAME_AKS" ] && [ -n "$RG" ] && [ -n "$ID_SUB" ]; then

    if ! connect_aks; then
        echo -e "FAILED! Couldn't connect to $NAME_AKS."
        exit 1
    fi

    if check_connect; then
        set_max_replicas

    else
        echo -e "FAILED! Couldn't connect to $NAME_AKS."
        exit 1
    fi

else
    echo -e "Parámetros incorrectos"
    exit 1
fi


