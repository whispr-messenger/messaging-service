#!/bin/bash

echo "📨 Test du Messaging Service"
echo "============================"

# Couleurs pour l'affichage
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration du service
SERVICE_NAME="Messaging Service"
SERVICE_PORT=4000
BASE_URL="http://localhost:$SERVICE_PORT"

# Fonction pour tester un endpoint
test_endpoint() {
    local endpoint_name=$1
    local url=$2
    local expected_status=$3
    local method=${4:-GET}
    
    echo -n "  Testing $endpoint_name... "
    
    response=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$url" 2>/dev/null)
    
    if [ "$response" = "$expected_status" ]; then
        echo -e "${GREEN}✅ OK${NC} (HTTP $response)"
        return 0
    else
        echo -e "${RED}❌ FAILED${NC} (HTTP $response, expected $expected_status)"
        return 1
    fi
}

# Fonction pour tester un endpoint avec authentification
test_auth_endpoint() {
    local endpoint_name=$1
    local url=$2
    
    echo -n "  Testing $endpoint_name auth... "
    
    # Test sans token (doit retourner 401)
    response=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
    
    if [ "$response" = "401" ]; then
        echo -e "${GREEN}✅ AUTH OK${NC} (HTTP 401 - auth required)"
        return 0
    else
        echo -e "${YELLOW}⚠️  WARNING${NC} (HTTP $response, expected 401 for auth)"
        return 1
    fi
}

echo ""
echo -e "${BLUE}🔍 Vérification du service...${NC}"
echo ""

# Vérifier si le service est en cours d'exécution
if ! lsof -i :$SERVICE_PORT | grep LISTEN >/dev/null 2>&1; then
    echo -e "${RED}❌ Service not running on port $SERVICE_PORT${NC}"
    echo "Please start the service with: mix phx.server"
    exit 1
else
    echo -e "${GREEN}✅ Service is running on port $SERVICE_PORT${NC}"
fi

echo ""
echo -e "${BLUE}🧪 Tests de connectivité...${NC}"
echo ""

# Tests des endpoints principaux
test_endpoint "Root endpoint" "$BASE_URL/" "200"
test_endpoint "Health check" "$BASE_URL/api/health" "200"

echo ""
echo -e "${BLUE}🔐 Tests d'authentification...${NC}"
echo ""

# Tests des endpoints protégés
test_auth_endpoint "Conversations API" "$BASE_URL/api/conversations"
test_auth_endpoint "Messages API" "$BASE_URL/api/messages"

echo ""
echo -e "${BLUE}🌐 Tests WebSocket...${NC}"
echo ""

# Test de connexion WebSocket (basique)
echo -n "  Testing WebSocket connection... "
if command -v wscat >/dev/null 2>&1; then
    # Si wscat est disponible, tester la connexion WebSocket
    timeout 3 wscat -c "ws://localhost:$SERVICE_PORT/socket" >/dev/null 2>&1
    if [ $? -eq 0 ] || [ $? -eq 124 ]; then  # 124 = timeout (connexion réussie)
        echo -e "${GREEN}✅ WebSocket OK${NC}"
    else
        echo -e "${RED}❌ WebSocket FAILED${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  wscat not available, skipping WebSocket test${NC}"
fi

echo ""
echo -e "${BLUE}📊 Résumé du service...${NC}"
echo ""

echo "Service: $SERVICE_NAME"
echo "Port: $SERVICE_PORT"
echo "Base URL: $BASE_URL"
echo ""
echo "Endpoints disponibles:"
echo "  🏠 Root: $BASE_URL/"
echo "  ❤️  Health: $BASE_URL/api/health"
echo "  💬 Conversations: $BASE_URL/api/conversations"
echo "  📝 Messages: $BASE_URL/api/messages"
echo "  🌐 WebSocket: ws://localhost:$SERVICE_PORT/socket"
echo ""

# Afficher les informations du processus
echo "Processus en cours:"
lsof -i :$SERVICE_PORT | grep LISTEN

echo ""
echo -e "${GREEN}✨ Tests du Messaging Service terminés !${NC}"