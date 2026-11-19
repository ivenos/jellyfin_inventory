// What Jellyfin itself shows is under its keys in src/strings of jellyfin-web 12.4.
const WORDS = {
    en: {
        TabServer: 'Server', TabDashboard: 'Dashboard', General: 'General', HeaderBranding: 'Branding', HeaderUsers: 'Users',
        HeaderLibraries: 'Libraries', TitlePlayback: 'Playback', HeaderDevices: 'Devices', HeaderActivity: 'Activity',
        LiveTV: 'Live TV', HeaderDVR: 'DVR', TabPlugins: 'Plugins', TabAdvanced: 'Advanced', TabNetworking: 'Networking',
        HeaderApiKeys: 'API Keys', HeaderBackups: 'Backups', TabLogs: 'Logs', TabScheduledTasks: 'Scheduled Tasks',
        Menu: 'Menu', LabelLanguage: 'Language',
        Title: 'Inventory demo',
        OpensItem: 'On a server this opens the item in Jellyfin.',
        OnlyPage: 'This demo has only the {0} page.',
    },
    de: {
        TabServer: 'Server', TabDashboard: 'Übersicht', General: 'Allgemein', HeaderBranding: 'Branding', HeaderUsers: 'Benutzer',
        HeaderLibraries: 'Bibliotheken', TitlePlayback: 'Wiedergabe', HeaderDevices: 'Geräte', HeaderActivity: 'Aktivitäten',
        LiveTV: 'Live-TV', HeaderDVR: 'Digitaler Rekorder', TabPlugins: 'Plugins', TabAdvanced: 'Erweitert', TabNetworking: 'Netzwerk',
        HeaderApiKeys: 'API-Schlüssel', HeaderBackups: 'Backups', TabLogs: 'Protokoll', TabScheduledTasks: 'Geplante Aufgaben',
        Menu: 'Menü', LabelLanguage: 'Sprache',
        Title: 'Inventory-Demo',
        OpensItem: 'Auf einem Server öffnet das den Eintrag in Jellyfin.',
        OnlyPage: 'Diese Demo hat nur die Seite {0}.',
    },
    es: {
        TabServer: 'Servidor', TabDashboard: 'Panel de control', General: 'General', HeaderBranding: 'Personalización de apariencia',
        HeaderUsers: 'Usuarios', HeaderLibraries: 'Bibliotecas', TitlePlayback: 'Reproducción', HeaderDevices: 'Dispositivos',
        HeaderActivity: 'Actividad', LiveTV: 'Televisión en vivo', HeaderDVR: 'Grabador Digital (DVR)', TabPlugins: 'Complementos',
        TabAdvanced: 'Avanzado', TabNetworking: 'Redes', HeaderApiKeys: 'Claves API', HeaderBackups: 'Copias de seguridad',
        TabLogs: 'Registros', TabScheduledTasks: 'Tareas programadas',
        Menu: 'Menú', LabelLanguage: 'Idioma',
        Title: 'Demo de Inventory',
        OpensItem: 'En un servidor, esto abre el elemento en Jellyfin.',
        OnlyPage: 'Esta demo solo tiene la página {0}.',
    },
    fr: {
        TabServer: 'Serveur', TabDashboard: 'Tableau de bord', General: 'Général', HeaderBranding: 'Slogan', HeaderUsers: 'Utilisateurs',
        HeaderLibraries: 'Médiathèques', TitlePlayback: 'Lecture', HeaderDevices: 'Appareils', HeaderActivity: 'Activité',
        LiveTV: 'TV en direct', HeaderDVR: 'DVR', TabPlugins: 'Extensions', TabAdvanced: 'Avancé', TabNetworking: 'Réseau',
        HeaderApiKeys: 'Clés API', HeaderBackups: 'Sauvegardes', TabLogs: 'Journaux', TabScheduledTasks: 'Tâches planifiées',
        Menu: 'Menu', LabelLanguage: 'Langue',
        Title: "Démo d'Inventory",
        OpensItem: "Sur un serveur, cela ouvre l'élément dans Jellyfin.",
        OnlyPage: "Cette démo n'a que la page {0}.",
    },
    it: {
        TabServer: 'Server', TabDashboard: 'Pannello di controllo', General: 'Generale', HeaderBranding: 'Personalizza',
        HeaderUsers: 'Utenti', HeaderLibraries: 'Librerie', TitlePlayback: 'Riproduzione', HeaderDevices: 'Dispositivi',
        HeaderActivity: 'Attività', LiveTV: 'Diretta TV', HeaderDVR: 'Video registratore digitale', TabPlugins: 'Plugin',
        TabAdvanced: 'Avanzato', TabNetworking: 'Rete', HeaderApiKeys: 'Chiavi API', HeaderBackups: 'Backup', TabLogs: 'Log',
        TabScheduledTasks: 'Operazioni Pianificate',
        Menu: 'Menù', LabelLanguage: 'Lingua',
        Title: 'Demo di Inventory',
        OpensItem: "Su un server, questo apre l'elemento in Jellyfin.",
        OnlyPage: 'Questa demo ha solo la pagina {0}.',
    },
};

export function word(key) {
    return (WORDS[document.documentElement.lang] ?? WORDS.en)[key];
}

export function translate(name) {
    document.title = word('Title');
    document.querySelector('#demoDrawer [aria-current] span').textContent = name;
    document.querySelectorAll('[data-word]').forEach((node) => { node.textContent = word(node.dataset.word); });
    document.querySelectorAll('[data-label]').forEach((node) => { node.setAttribute('aria-label', word(node.dataset.label)); });
}
