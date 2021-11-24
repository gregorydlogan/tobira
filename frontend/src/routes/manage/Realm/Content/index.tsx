import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { graphql, useFragment, PreloadedQuery } from "react-relay";

import { Root } from "../../../../layout/Root";
import type { ContentManageQuery } from "../../../../query-types/ContentManageQuery.graphql";
import type { ContentManageData$key } from "../../../../query-types/ContentManageData.graphql";
import { loadQuery } from "../../../../relay";
import { NotAuthorized, PathInvalid } from "..";
import { RealmSettingsContainer } from "../util";
import { Nav } from "../../../../layout/Navigation";
import { makeRoute } from "../../../../rauta";
import { QueryLoader } from "../../../../util/QueryLoader";
import { Spinner } from "../../../../ui/Spinner";
import { AddButtons } from "./AddButtons";
import { Block } from "./Block";


export const PATH = "/~manage/realm/content";

export const ManageRealmContentRoute = makeRoute<PreloadedQuery<ContentManageQuery>, ["path"]>({
    path: PATH,
    queryParams: ["path"],
    prepare: ({ queryParams: { path } }) => loadQuery(query, { path }),
    render: queryRef => <QueryLoader {...{ query, queryRef }} render={result => {
        const { realm } = result;
        const nav = realm ? <Nav fragRef={realm} /> : [];

        let children = null;
        if (!realm) {
            children = <PathInvalid />;
        } else if (!realm.canCurrentUserEdit) {
            children = <NotAuthorized />;
        } else {
            children = <ManageContent fragRef={realm} />;
        }

        return <Root nav={nav} userQuery={result}>
            {children}
        </Root>;
    }} />,
    dispose: queryRef => queryRef.dispose(),
});


const query = graphql`
    query ContentManageQuery($path: String!) {
        ... UserData
        realm: realmByPath(path: $path) {
            canCurrentUserEdit
            ... NavigationData
            ... ContentManageData
        }
    }
`;


type Props = {
    fragRef: ContentManageData$key;
};

const ManageContent: React.FC<Props> = ({ fragRef }) => {
    const { t } = useTranslation();

    const realm = useFragment(
        graphql`
            fragment ContentManageData on Realm {
                name
                path
                isRoot
                ... BlockRealmData
                blocks {
                    id
                }
            }
        `,
        fragRef,
    );
    const { name, isRoot: realmIsRoot, blocks } = realm;


    const [inFlight, setInFlight] = useState(false);

    const onCommit = () => {
        setInFlight(true);
    };

    const onCompleted = () => {
        setInFlight(false);
    };

    const onError = () => {
        setInFlight(false);
    };


    return <RealmSettingsContainer>
        <h1>
            {realmIsRoot
                ? t("manage.realm.content.heading-root")
                : t("manage.realm.content.heading", { realm: name })}
        </h1>

        <div css={{
            display: "flex",
            flexDirection: "column",
            rowGap: 16,
            padding: 0,
            // To position the loading overlay
            position: "relative",
        }}>
            {blocks.filter(block => block != null).map((block, index) => (
                <React.Fragment key={block.id}>
                    <AddButtons index={index} />

                    <Block {...{ realm, index, onCommit, onCompleted, onError }} />
                </React.Fragment>
            ))}
            <AddButtons index={blocks.length} />

            {inFlight && <div css={{
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                backgroundColor: "rgba(255, 255, 255, 0.5)",
                position: "absolute",
                width: "100%",
                height: "100%",
            }}>
                <Spinner size={20} />
            </div>}
        </div>
    </RealmSettingsContainer>;
};
