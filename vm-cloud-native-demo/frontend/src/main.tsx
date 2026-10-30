import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import '@patternfly/react-core/dist/styles/base.css';
import './space.css';
import App from './App';

const container = document.getElementById('root');
if (!container) {
  throw new Error('missing #root');
}
createRoot(container).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
