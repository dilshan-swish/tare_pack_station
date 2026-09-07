import { useState } from "react";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { getConfig, clearConfig } from "./api";
import { Layout } from "./Layout";
import { LoginPage } from "./pages/LoginPage";
import { BrandsPage } from "./pages/BrandsPage";
import { WeightsPage } from "./pages/WeightsPage";
import { TabletsPage } from "./pages/TabletsPage";
import { DeviceDetailPage } from "./pages/DeviceDetailPage";
import { DashboardPage } from "./pages/DashboardPage";
import { TrainingDataPage } from "./pages/TrainingDataPage";
import { AnalyticsLayout } from "./pages/AnalyticsLayout";
import { AnalyticsAskPage } from "./pages/AnalyticsAskPage";
import { AnalyticsHistoryPage } from "./pages/AnalyticsHistoryPage";
import { AnalyticsReportsPage } from "./pages/AnalyticsReportsPage";
import { AnalyticsAlertsPage } from "./pages/AnalyticsAlertsPage";
import { AnalyticsDataPage } from "./pages/AnalyticsDataPage";
import { AnalyticsSettingsPage } from "./pages/AnalyticsSettingsPage";
import { ConfirmHost } from "./confirmDialog";

export default function App() {
  // The portal auto-connects from config (see getConfig / .env), so normally
  // there is no login step. The Connection screen only appears if the user
  // opens it to override the URL/key, or if nothing is configured at all.
  const [override, setOverride] = useState(false);
  const connected = !!getConfig() && !override;

  if (!connected) {
    return (
      <LoginPage
        onConnected={() => setOverride(false)}
        onCancel={getConfig() ? () => setOverride(false) : undefined}
      />
    );
  }

  return (
    <BrowserRouter>
      <ConfirmHost />
      <Layout
        onConnection={() => {
          clearConfig();
          setOverride(true);
        }}
      >
        <Routes>
          <Route path="/" element={<BrandsPage />} />
          <Route path="/brands/:brandId/weights" element={<WeightsPage />} />
          <Route path="/tablets" element={<TabletsPage />} />
          <Route path="/devices/:deviceId" element={<DeviceDetailPage />} />
          <Route path="/dashboard" element={<DashboardPage />} />
          <Route path="/training-data" element={<TrainingDataPage />} />
          <Route path="/analytics" element={<AnalyticsLayout />}>
            <Route index element={<AnalyticsAskPage />} />
            <Route path="history" element={<AnalyticsHistoryPage />} />
            <Route path="reports" element={<AnalyticsReportsPage />} />
            <Route path="alerts" element={<AnalyticsAlertsPage />} />
            <Route path="data" element={<AnalyticsDataPage />} />
            <Route path="settings" element={<AnalyticsSettingsPage />} />
          </Route>
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </Layout>
    </BrowserRouter>
  );
}
