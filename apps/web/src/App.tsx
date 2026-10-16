import { Navigate, Route, Routes } from 'react-router-dom';
import { useSession } from './store/session';
import Login from './pages/Login';
import Hub from './pages/Hub';
import SiteShell from './renderer/SiteShell';
import Builder from './builder/Builder';
import IsolationLedger from './pages/IsolationLedger';

export default function App() {
  const token = useSession(s => s.token);
  return (
    <Routes>
      <Route path="/login" element={token ? <Navigate to="/" replace /> : <Login />} />
      <Route path="/" element={token ? <Hub /> : <Navigate to="/login" replace />} />
      <Route path="/hub/ledger" element={token ? <IsolationLedger /> : <Navigate to="/login" replace />} />
      <Route path="/builder/:siteId" element={token ? <Builder /> : <Navigate to="/login" replace />} />
      <Route path="/:slug/*" element={token ? <SiteShell /> : <Navigate to="/login" replace />} />
    </Routes>
  );
}
