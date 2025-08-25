# Guide d'utilisation des WebSockets - Messaging Service

## 🚀 **Configuration Terminée**

✅ **Phoenix Channels configurés et fonctionnels !**

### 📡 **Endpoints WebSocket Disponibles**

```
ws://localhost:4000/socket/websocket
```

### 🔌 **Channels Disponibles**

#### 1. **UserChannel** - `user:{user_id}`
- **Fonctionnalité** : Présence globale, notifications utilisateur
- **Authentification** : Token JWT requis
- **Événements entrants** :
  - `ping` → Maintenir la connexion
  - `update_presence` → Changer le statut (online/away/busy)
  - `mark_all_read` → Marquer plusieurs conversations comme lues

- **Événements sortants** :
  - `new_message` → Nouveau message reçu
  - `conversation_updated` → Conversation modifiée
  - `user_presence_changed` → Changement de présence d'un contact
  - `notification` → Notification système

#### 2. **ConversationChannel** - `conversation:{conversation_id}`
- **Fonctionnalité** : Messages temps réel par conversation
- **Authentification** : Membre de la conversation requis
- **Événements entrants** :
  - `send_message` → Envoyer un message
  - `typing_start` → Commencer à taper
  - `typing_stop` → Arrêter de taper
  - `mark_as_read` → Marquer un message comme lu
  - `add_reaction` → Ajouter une réaction 
  - `remove_reaction` → Supprimer une réaction

- **Événements sortants** :
  - `new_message` → Nouveau message dans la conversation
  - `typing_indicator` → Indicateur de frappe
  - `read_receipt` → Accusé de lecture
  - `reaction_added` → Nouvelle réaction
  - `reaction_removed` → Réaction supprimée
  - `user_joined` → Utilisateur rejoint la conversation
  - `user_left` → Utilisateur quitte la conversation

### 🔐 **Authentification**

```javascript
// Connexion avec token JWT
const socket = new Phoenix.Socket("/socket", {
  params: { token: "your_jwt_token" }
});

socket.connect();
```

### 📝 **Exemples d'utilisation**

#### **Rejoindre les channels**

```javascript
// Channel utilisateur pour les notifications globales
const userChannel = socket.channel(`user:${userId}`, {});
userChannel.join()
  .receive("ok", resp => console.log("User channel joined", resp))
  .receive("error", resp => console.log("Unable to join user channel", resp));

// Channel conversation pour les messages temps réel
const conversationChannel = socket.channel(`conversation:${conversationId}`, {});
conversationChannel.join()
  .receive("ok", resp => console.log("Conversation joined", resp))
  .receive("error", resp => console.log("Unable to join conversation", resp));
```

#### **Envoyer un message**

```javascript
conversationChannel.push("send_message", {
  message_type: "text",
  content: "Hello World!",
  metadata: {},
  client_random: Math.floor(Math.random() * 1000000000)
})
.receive("ok", resp => console.log("Message sent", resp))
.receive("error", resp => console.log("Error sending message", resp));
```

#### **Indicateurs de frappe**

```javascript
// Commencer à taper
conversationChannel.push("typing_start", {});

// Arrêter de taper
conversationChannel.push("typing_stop", {});

// Écouter les indicateurs des autres
conversationChannel.on("typing_indicator", payload => {
  console.log(`${payload.user_id} is ${payload.action} typing`);
});
```

#### **Réactions aux messages**

```javascript
// Ajouter une réaction
conversationChannel.push("add_reaction", {
  message_id: "message-uuid",
  reaction: "👍"
});

// Supprimer une réaction
conversationChannel.push("remove_reaction", {
  message_id: "message-uuid", 
  reaction: "👍"
});
```

#### **Présence utilisateur**

```javascript
// Mettre à jour le statut
userChannel.push("update_presence", {
  status: "away" // online, away, busy, offline
});

// Écouter les changements de présence
userChannel.on("user_presence_changed", payload => {
  console.log(`User ${payload.user_id} is now ${payload.status}`);
});
```

### 🔄 **Broadcasting Automatique**

Le système broadcaste automatiquement :

- ✅ **Nouveaux messages** → Tous les membres de la conversation
- ✅ **Changements de présence** → Contacts de l'utilisateur
- ✅ **Accusés de lecture** → Expéditeur du message
- ✅ **Réactions** → Tous les membres de la conversation
- ✅ **Notifications système** → Utilisateur concerné

### 🚦 **État du Projet**

| Fonctionnalité | Statut | Description |
|---------------|---------|-------------|
| **Phoenix Channels** | ✅ Terminé | Configuration complète |
| **UserSocket** | ✅ Terminé | Authentification JWT |
| **UserChannel** | ✅ Terminé | Présence & notifications |
| **ConversationChannel** | ✅ Terminé | Messages temps réel |
| **Phoenix.Presence** | ✅ Terminé | Tracking utilisateurs |
| **PubSub Broadcasting** | ✅ Terminé | Distribution événements |
| **Integration Contextes** | ✅ Terminé | Connexion avec Messages |

### 🎯 **Prochaines Étapes Suggérées**

1. **Tests d'intégration** - Tester les WebSockets avec un client
2. **gRPC Integration** - Ajouter communication inter-services
3. **Redis Caching** - Implémenter le cache pour performances  
4. **Rate Limiting** - Protection contre spam
5. **Metrics & Monitoring** - Observabilité des WebSockets

### 📊 **Architecture Réalisée**

```
Client (Frontend)
    ↕ WebSocket
PhoenixChannels (Messaging-Service)
    ↕ PubSub  
Phoenix.Presence + Broadcasting
    ↕ Context Layer
Ecto + PostgreSQL
```

Le **messaging-service** est maintenant prêt pour la **communication temps réel** ! 🎉
