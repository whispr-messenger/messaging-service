# Politique de Sécurité - Service Messagerie

## 1. Introduction

### 1.1 Objectif du Document
Cette politique de sécurité définit les mesures techniques et pratiques à implémenter pour protéger le service de messagerie (Messaging Service) de l'application Whispr dans le cadre de notre projet de fin d'études.

### 1.2 Contexte et Importance
Le service de messagerie gère l'ensemble des communications entre utilisateurs, incluant les messages texte, médias et métadonnées associées. Il constitue le cœur fonctionnel de l'application et doit garantir la confidentialité, l'intégrité et la disponibilité des échanges privés entre utilisateurs.

### 1.3 Principes Fondamentaux
- **Chiffrement bout-en-bout**: Protection du contenu des messages contre toute lecture non autorisée
- **Architecture résiliente**: Conception visant une haute disponibilité et tolérance aux pannes
- **Confidentialité des métadonnées**: Limitation de l'exposition des informations contextuelles
- **Livraison fiable**: Garantie de non-perte et non-duplication des messages
- **Séparation des privilèges**: Isolation stricte entre les différentes conversations
- **Défense en profondeur**: Multiples couches de protection complémentaires

## 2. Protection des Communications

### 2.1 Chiffrement Bout-en-Bout

#### 2.1.1 Protocole de Chiffrement Signal
- Implémentation du protocole Signal pour le chiffrement E2EE
- Utilisation de la Double Ratchet pour la forward secrecy
- Rotation régulière des clés avec Triple Diffie-Hellman (3DH)
- Génération côté client des clés de chiffrement
- Signature cryptographique des messages avec vérification côté serveur

#### 2.1.2 Gestion des Clés
- Distribution sécurisée des PreKeys pour l'établissement initial
- Stockage des clés publiques uniquement sur le serveur
- Rotation automatique des clés après période d'inactivité
- Suppression des clés obsolètes selon politique de rétention
- Mécanisme de vérification des clés entre appareils (safety numbers)

#### 2.1.3 Vérification d'Intégrité
- Vérification de l'intégrité des messages sans accès au contenu déchiffré
- Détection des altérations via signatures
- Avertissement aux utilisateurs en cas d'anomalie cryptographique
- Mécanisme de rejet des messages corrompus ou falsifiés
- Protection contre les attaques par rejeu via nonces

### 2.2 Protection des Métadonnées

#### 2.2.1 Minimisation des Métadonnées
- Limitation des métadonnées stockées au strict nécessaire
- Pseudonymisation des identifiants techniques
- Séparation des données d'identité et des métadonnées de communication
- Dissociation des informations de routage et contenu
- Agrégation des métadonnées pour les fonctionnalités analytiques

#### 2.2.2 Chiffrement des Métadonnées Sensibles
- Chiffrement des informations de sujet/titre des conversations
- Protection des listes de participants
- Obscurcissement des patterns de communication
- Stockage chiffré des timestamps précis
- Traitement sécurisé des informations de présence

### 2.3 Sécurité des WebSockets

#### 2.3.1 Établissement de Connexion
- Authentification forte pour chaque connexion WebSocket
- Utilisation de tokens à usage unique pour l'établissement initial
- Vérification à double facteur pour les appareils non reconnus
- Renouvellement périodique des sessions WebSocket
- Limitation du nombre de connexions simultanées par utilisateur

#### 2.3.2 Protection des Canaux
- Chiffrement TLS 1.3 obligatoire pour toutes les connexions
- Protection contre l'interception via certificats épinglés (certificate pinning)
- Isolation des canaux par conversation et par utilisateur
- Validation des autorisations à chaque message
- Délai d'inactivité paramétrable avant déconnexion

## 3. Gestion des Conversations

### 3.1 Contrôle d'Accès aux Conversations

#### 3.1.1 Modèle de Sécurité des Conversations
- Vérification systématique de l'appartenance à la conversation pour chaque action
- Isolation complète entre conversations différentes
- Propagation immédiate des changements d'appartenance aux groupes
- Vérification des blocages entre utilisateurs
- Différents niveaux d'accès selon le type de conversation (direct/groupe)

#### 3.1.2 Autorisations Granulaires
- Droits distincts pour lecture, écriture, administration
- Respect des rôles définis dans user-service pour les groupes
- Droit de suppression limité aux messages envoyés par l'utilisateur
- Restrictions temporelles pour certaines opérations sensibles
- Validation contextuelle des demandes de changement de paramètres

#### 3.1.3 Vérification des Permissions
- Validation à chaque opération CRUD sur les messages
- Cache sécurisé des permissions pour optimiser les performances
- Revalidation périodique des autorisations pour sessions longues
- Vérification cross-service pour les groupes et contacts
- Journalisation des opérations administratives

### 3.2 Protection des Messages

#### 3.2.1 Cycle de Vie des Messages
- Persistance garantie des messages envoyés jusqu'à confirmation de livraison
- Protection contre les duplications via identifiants uniques côté client
- Mécanismes de retransmission sécurisée en cas d'échec
- Suppression définitive selon politiques de rétention
- Stockage séparé pour contenu et métadonnées

#### 3.2.2 Médias et Pièces Jointes
- Validation cryptographique des médias avant acceptation
- Génération de hashs perceptuels pour détection de contenu inapproprié
- Chiffrement des médias distinct du chiffrement des messages
- Liens temporaires et authentifiés pour l'accès aux médias
- Suppression coordonnée avec media-service

#### 3.2.3 Messages Éphémères
- Support des messages à disparition automatique
- Paramètres de durée variables selon conversation
- Garantie de suppression après délai même en cas d'indisponibilité temporaire
- Protection contre l'extraction non autorisée
- Journalisation minimale respectant la nature éphémère

### 3.3 Gestion des Statuts de Livraison

#### 3.3.1 Accusés de Réception
- Protection de la confidentialité des statuts de lecture
- Respect des préférences utilisateur pour les accusés
- Authentification pour chaque mise à jour de statut
- Consolidation sécurisée à travers les appareils
- Prévention de la fuite d'informations via timing

#### 3.3.2 Synchronisation Multi-Appareils
- Distribution sécurisée aux appareils multiples d'un même utilisateur
- Vérification des appareils autorisés via auth-service
- Isolation entre appareils de terminaux différents
- Suppression synchronisée sur tous les appareils
- Protection contre les désynchronisations malveillantes

## 4. Protection des Données

### 4.1 Classification des Données

#### 4.1.1 Données de Contenu
- Messages texte : hautement sensibles, stockés uniquement sous forme chiffrée
- Médias partagés : hautement sensibles, référencés via identifiants sécurisés
- Réactions et annotations : modérément sensibles, chiffrées avec le message
- Messages système : faiblement sensibles, protection contre la falsification

#### 4.1.2 Données de Structure
- Identifiants de conversation : modérément sensibles, dissociés des utilisateurs quand possible
- Listes de participants : sensibles, accès restreint
- Timestamps de message : modérément sensibles, précision réduite quand possible
- Métadonnées de conversation : sensibles, protection adaptée

#### 4.1.3 Données Opérationnelles
- Statuts de livraison : modérément sensibles, accès contrôlé
- Indicateurs de présence : sensibles, accès temporaire et contrôlé
- Métriques d'utilisation : agrégées et anonymisées
- Logs système : expurgés des données sensibles

### 4.2 Chiffrement au Repos

#### 4.2.1 Données dans PostgreSQL
- Contenu des messages toujours stocké chiffré
- Chiffrement transparent de la base de données complète (TDE)
- Isolation des conversations via partitionnement
- Clés de chiffrement gérées via service externe (KMS)
- Rotation périodique des clés de chiffrement secondaires

#### 4.2.2 Données Temporaires
- TTL strict sur toutes les données Redis (max 24h)
- Clés Redis conçues pour éviter les collisions et inférences
- Pas de stockage en clair des contenus de message en cache
- Purge régulière des données temporaires ETS/Mnesia
- Protection contre la persistance non autorisée (swap, crash dumps)

### 4.3 Chiffrement en Transit

#### 4.3.1 Communications Externes
- TLS 1.3 obligatoire pour toutes les API et WebSockets
- Configuration restrictive des suites cryptographiques
- Perfect Forward Secrecy (PFS) pour toutes les connexions
- HTTP Strict Transport Security (HSTS)
- Validation rigoureuse des certificats clients

#### 4.3.2 Communications Inter-Services
- mTLS (TLS mutuel) pour l'authentification service-à-service
- Chiffrement de transport pour toutes les communications gRPC
- Authentification forte pour chaque requête inter-service
- Isolation réseau entre les services via Network Policies
- Création dynamique de certificats via service mesh

## 5. Résilience et Disponibilité

### 5.1 Architecture Tolérante aux Pannes

#### 5.1.1 Supervision OTP
- Stratégies de supervision adaptées à chaque type de processus
- Isolation des défaillances via hiérarchie de superviseurs
- Redémarrage automatique avec stratégies exponentielles
- Séparation entre processus d'état et de traitement
- Détection et récupération des processus bloqués

#### 5.1.2 Distribution Erlang
- Clustering sécurisé entre nœuds Elixir
- Communication chiffrée entre nœuds du cluster
- Partitionnement intelligent des données et processus
- Quorum pour les opérations critiques
- Récupération automatique après partition réseau

### 5.2 Protection Contre les Surcharges

#### 5.2.1 Limitation de Débit (Rate Limiting)
- Par utilisateur : 100 messages par minute
- Par conversation : adaptatif selon le nombre de participants
- Par connexion : 200 opérations par minute
- Délai progressif après atteinte des limites
- Priorisation des messages critiques

#### 5.2.2 Back Pressure et Circuit Breakers
- Mécanismes de back pressure pour contrôler la charge
- Circuit breakers pour les services externes dégradés
- File d'attente prioritaire pour les opérations critiques
- Dégradation gracieuse des fonctionnalités non essentielles
- Monitoring en temps réel des points de saturation

### 5.3 Récupération après Incident

#### 5.3.1 Persistance Garantie
- Journalisation des messages avant confirmation client
- Double écriture pour les opérations critiques
- Mécanisme de récupération des messages en attente
- Reconstruction possible à partir des événements journalisés
- Point de contrôle régulier de l'état du système

#### 5.3.2 Stratégies de Reprise
- RPO (Recovery Point Objective) : maximum 5 minutes de perte potentielle
- RTO (Recovery Time Objective) : reprise sous 10 minutes
- Procédures de failover automatisé entre nœuds
- Restauration séquentielle priorisée des fonctionnalités
- Tests réguliers des procédures de récupération

## 6. Protection Contre les Menaces

### 6.1 Détection des Abus

#### 6.1.1 Monitoring du Comportement
- Détection des patterns d'envoi anormaux (spam)
- Identification des conversations à volume inhabituel
- Surveillance des tentatives d'accès non autorisés
- Analyse des patterns de connexion suspects
- Alertes sur les anomalies statistiques

#### 6.1.2 Limitation des Abus
- Throttling progressif des comptes suspects
- Captcha ou défis cryptographiques après comportement suspect
- Limitation des destinataires pour nouveaux comptes
- Restrictions temporaires après signalements multiples
- Protection contre l'amplification des notifications

### 6.2 Protection Contre les Attaques

#### 6.2.1 Injection et Validation
- Validation stricte des entrées avec Ecto Changesets
- Paramètres préparés pour toutes les requêtes PostgreSQL
- Désérialisation sécurisée des messages chiffrés
- Protection contre les attaques par pollution de cache
- Validation des structures protobuf/gRPC

#### 6.2.2 Protection Contre les Manipulations
- Vérification d'intégrité via hachage pour les données critiques
- Tokens d'opération à usage unique pour modifications sensibles
- Détection des tentatives de modification de statut non autorisées
- Protection contre la manipulation d'ordre des messages
- Vérifications temporelles contre les attaques par rejeu

#### 6.2.3 Sécurité des WebSockets
- Protection contre les détournements de session WebSocket
- Détection des comportements anormaux sur les canaux Phoenix
- Limitation de la fréquence des abonnements/désabonnements
- Validation de l'origine des connexions WebSocket
- Protection contre l'épuisement des ressources via connexions multiples

## 7. Intégration avec les Autres Services

### 7.1 Communication avec le Service d'Authentification

#### 7.1.1 Validation des Identités
- Vérification cryptographique des tokens JWT
- Synchronisation sécurisée des informations d'appareil
- Détection des tentatives d'usurpation
- Révocation immédiate des accès après déconnexion
- Double validation pour les opérations critiques

#### 7.1.2 Gestion des Sessions
- Mapping sécurisé entre sessions WebSocket et identités
- Déconnexion coordonnée sur l'ensemble des appareils
- Isolation des sessions par appareil
- Rotation des identifiants de session
- Monitoring des connexions simultanées

### 7.2 Intégration avec User Service

#### 7.2.1 Synchronisation des Relations
- Propagation sécurisée des événements de blocage utilisateur
- Vérification croisée des appartenances aux groupes
- Validation des permissions via user-service
- Mise à jour synchronisée des métadonnées de groupe
- Circuit breaker en cas d'indisponibilité temporaire

#### 7.2.2 Respect des Paramètres Utilisateur
- Application des paramètres de confidentialité des utilisateurs
- Respect des préférences de statut de lecture
- Synchronisation des paramètres de notification
- Gestion des autorisations de présence (dernière vue, etc.)
- Filtre des utilisateurs bloqués dans les conversations de groupe

### 7.3 Intégration avec Media Service

#### 7.3.1 Gestion des Médias
- Transmission sécurisée des références de médias
- Validation préalable avant acceptation
- URLs signées à durée limitée pour l'accès
- Suppression coordonnée des médias après expiration
- Vérification des limites de taille et format

#### 7.3.2 Modération de Contenu
- Génération de hashs perceptuels pour vérification
- Vérification via moderation-service avant acceptation définitive
- Marquage sécurisé des contenus potentiellement inappropriés
- Isolation des médias en attente de vérification
- Traçabilité des décisions de modération

## 8. Détection et Réponse aux Incidents

### 8.1 Journalisation et Surveillance

#### 8.1.1 Télémétrie Sécurisée
- Métriques agrégées pour analyse des patterns
- Journalisation structurée des événements avec contexte
- Traces d'exécution pour diagnostic (sans données sensibles)
- Monitoring de santé des processus Erlang
- Alerte sur anomalies de performance ou disponibilité

#### 8.1.2 Détection d'Anomalies
- Profils de base pour utilisation normale
- Détection des écarts statistiques significatifs
- Alertes sur seuils dynamiques adaptés au trafic
- Corrélation entre événements système et applicatifs
- Détection précoce des tentatives d'attaque distribuée

### 8.2 Gestion des Incidents

#### 8.2.1 Classification des Incidents
- Niveaux de gravité définis :
  - Critique : Compromission du chiffrement ou fuite de messages
  - Élevé : Contournement des contrôles d'accès aux conversations
  - Moyen : Perturbation temporaire du service ou abus des fonctionnalités
  - Faible : Anomalies mineures n'affectant pas la sécurité des messages

#### 8.2.2 Procédures de Réponse
- Protocoles définis par type d'incident
- Chaîne d'escalade avec responsabilités assignées
- Procédures d'isolation pour limiter l'impact
- Documentation standardisée des incidents
- Analyse post-mortem systématique

## 9. Développement Sécurisé

### 9.1 Pratiques de Développement

#### 9.1.1 Principes de Code Sécurisé pour Elixir
- Application des patterns OTP pour l'isolation des défaillances
- Utilisation rigoureuse du typage via typespecs
- Validation exhaustive des messages inter-processus
- Gestion explicite des cas d'erreur
- Modèle de concurrence avec garanties de supervision

#### 9.1.2 Revue et Tests
- Revue de code obligatoire pour les composants cryptographiques
- Tests de propriété pour les invariants de sécurité
- Tests fuzz pour les parsers et décodeurs
- Vérification formelle pour les protocoles critiques
- Tests de charge pour validation des mécanismes de protection

### 9.2 Gestion des Dépendances

#### 9.2.1 Évaluation et Sélection
- Audit de sécurité des bibliothèques externes
- Préférence pour les dépendances avec historique de sécurité positif
- Vérification de la maintenance active des composants critiques
- Évaluation des pratiques de sécurité des mainteneurs
- Limitation des dépendances au strict nécessaire

#### 9.2.2 Maintenance et Mises à Jour
- Suivi des avis de sécurité pour l'écosystème Elixir/Erlang
- Processus accéléré pour les correctifs critiques
- Tests de régression après mises à jour
- Isolation des composants externes via abstraction
- Plan de contingence pour dépendances abandonnées

## 10. Protection des Données Personnelles

### 10.1 Conformité RGPD

#### 10.1.1 Principes Appliqués
- Minimisation des métadonnées stockées non chiffrées
- Finalités strictement définies pour chaque donnée collectée
- Impossibilité technique d'accéder au contenu des messages
- Limitation de la durée de conservation selon politiques configurables
- Intégrité et confidentialité par conception

#### 10.1.2 Droits des Utilisateurs
- Support technique pour l'effacement des données de message
- Portabilité des conversations via export chiffré
- Accès limité aux seules métadonnées propres à l'utilisateur
- Transparence sur les données collectées pour le fonctionnement du service
- Contrôle granulaire sur les paramètres de confidentialité

### 10.2 Gestion des Consentements

#### 10.2.1 Paramètres de Confidentialité
- Contrôle des statuts de lecture et indicateurs de livraison
- Gestion des indicateurs de frappe ("X est en train d'écrire...")
- Possibilité de désactiver les aperçus de notification
- Options pour la conservation des messages
- Paramètres pour la synchronisation multi-appareils

#### 10.2.2 Transparence
- Documentation claire sur la sécurité du chiffrement
- Indicateurs visuels sur l'état de sécurité des conversations
- Notifications des changements de clés cryptographiques
- Alertes en cas de comportements inhabituels
- Visibilité sur les appareils actifs dans la conversation

## 11. Sauvegarde et Récupération

### 11.1 Protection des Données

#### 11.1.1 Stratégie de Sauvegarde
- Sauvegarde incrémentielle de la base PostgreSQL
- Chiffrement des sauvegardes avec clés distinctes
- Séparation du stockage des clés et données
- Tests réguliers de restauration
- Rotation des sauvegardes avec rétention définie

#### 11.1.2 Continuité de Service
- Architecture multi-nœuds pour haute disponibilité
- Réplication synchrone pour les données critiques
- Basculement automatique en cas de défaillance
- Procédures documentées pour les incidents majeurs
- Exercices réguliers de simulation d'incident

### 11.2 Rétention et Suppression

#### 11.2.1 Politiques de Rétention
- Paramètres de rétention configurables par conversation
- Support des messages à disparition automatique
- Purge des messages selon règles prédéfinies
- Conservation minimale pour les métadonnées opérationnelles
- Archivage sécurisé pour les conversations inactives

#### 11.2.2 Suppression Définitive
- Procédure de suppression à plusieurs phases
- Effacement cryptographique pour les données sensibles
- Vérification de la propagation des suppressions
- Purge des caches et structures temporaires
- Coordination avec les autres services pour suppression complète

---

## Annexes

### A. Matrice des Risques et Contrôles

| Risque | Probabilité | Impact | Mesures de Contrôle |
|--------|-------------|--------|---------------------|
| Compromission du chiffrement E2E | Très faible | Critique | Implémentation stricte du protocole Signal, audits externes |
| Accès non autorisé aux conversations | Faible | Élevé | Vérification systématique des participants, authentification forte |
| Déni de service | Moyenne | Élevé | Architecture distribuée, rate limiting, circuit breakers |
| Fuite de métadonnées | Moyenne | Moyen | Minimisation des données, obfuscation des patterns de communication |
| Manipulation des statuts de livraison | Faible | Faible | Validation cryptographique, détection des incohérences |
| Injection via contenu de message | Moyenne | Moyen | Validation des entrées, isolation du contenu chiffré |
| Perte de messages | Faible | Élevé | Persistance garantie, acquittements, mécanismes de retransmission |

### B. Métriques de Sécurité

| Métrique | Objectif | Fréquence de Mesure |
|----------|----------|---------------------|
| Délai de livraison des messages | < 500ms (P95) | Temps réel |
| Taux d'erreurs cryptographiques | < 0.001% des messages | Quotidienne |
| Temps de détection des anomalies | < 2 minutes | Par incident |
| Taux de disponibilité du service | > 99.9% | Mensuelle |
| Couverture des tests de sécurité | > 95% des scénarios critiques | Par release |
| Exploitation réussie de mémoire | 0 occurrence | Continue |

### C. Références

- Signal Protocol Specification
- Erlang/OTP Security Guidelines
- OWASP Realtime API Security Cheat Sheet
- NIST Recommendations for E2E Encryption
- WebSocket Security Best Practices
- Phoenix Security Hardening Guide