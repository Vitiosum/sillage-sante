import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Sillage Sante',
  description: 'Teleconsultation et suivi de dossiers patients',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="fr">
      <body>
        <header className="barre">
          <strong>Sillage Sante</strong>
          <nav>
            <a href="/dossiers">Dossiers</a>
            <a href="/documents">Documents</a>
          </nav>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
