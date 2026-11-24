#!/usr/bin/env saba
import { Card } from "ui";
const emoji = "😀"; function Page(props) { return <Card title="Tom &amp; Jerry" lang="café &#x1F600;" {...props}>{emoji}<b>été</b>{...props.items}</Card>; }
export const view = () => <Page id="&lt;main&gt;"/>; const top = <footer/>;
