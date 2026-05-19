import React from 'react';
import ReactDOM from 'react-dom/client';
import './styles.css';

const App: React.FC = () => {
    return (
        <div className="app">
            <h1>Olá, Mundo!</h1>
            <p>Este é um aplicativo React básico.</p>
            <button onClick={() => alert('Botão clicado!')}>Clique em mim</button>
        </div>
    );
};

const rootElement = document.getElementById('root');
if (rootElement) {
    const root = ReactDOM.createRoot(rootElement);
    root.render(
        <React.StrictMode>
            <App />
        </React.StrictMode>
    );
} else {
    console.error('Elemento root não encontrado');
}